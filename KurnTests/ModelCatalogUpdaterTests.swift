import AgentHarness
import Foundation
import Testing
@testable import Kurn

/// The remote model catalog check: only while a cloud provider is in use, at most daily, applied
/// only once it validates, saved for the next launch, and used by the cost estimate. Serialized
/// because the overlay it installs is process-wide; it only ever lists test-only model IDs.
@MainActor
@Suite(.serialized)
struct ModelCatalogUpdaterTests {
    final class Calls: @unchecked Sendable {
        var count = 0
    }

    nonisolated static let document = Data(#"""
        {"format":"kurn.model-catalog","schema":1,"version":"\#(ModelCatalogDocument.bundledVersion)",
         "models":{"kurn-test-priced":{"context":64000,"price":{"input":2,"output":8,"cacheRead":0.5}}}}
        """#.utf8)

    struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let calls = Calls()
    }

    static func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: "ModelCatalogUpdaterTests-\(UUID().uuidString)"))
        return Fixture(directory: directory, defaults: defaults)
    }

    static func updater(_ fixture: Fixture, cloud: Bool = true, clock: @escaping () -> Date = Date.init,
                        response: @escaping @Sendable () throws -> Data = { ModelCatalogUpdaterTests.document }) -> ModelCatalogUpdater {
        let calls = fixture.calls
        return ModelCatalogUpdater(directory: fixture.directory, defaults: fixture.defaults, usesCloud: { cloud },
                                   fetch: { request in
            calls.count += 1
            #expect(request.url == ModelCatalogUpdater.sourceURL)
            #expect(request.httpMethod == "GET" && request.allHTTPHeaderFields?.isEmpty != false)
            return try response()
        }, now: clock)
    }

    @Test func nothingIsFetchedWithoutACloudProvider() async throws {
        let fixture = try Self.fixture()
        #expect(await Self.updater(fixture, cloud: false).refreshIfDue() == .noCloudProvider)
        #expect(fixture.calls.count == 0)
    }

    @Test func aValidCatalogIsAppliedSavedAndCheckedAgainOnlyADayLater() async throws {
        defer { ModelCatalogOverlay.install(nil) }
        let fixture = try Self.fixture()
        var now = Date()
        let updater = Self.updater(fixture, clock: { now })

        #expect(await updater.refreshIfDue() == .applied)
        #expect(ModelContextWindows.knownWindow(forModel: "kurn-test-priced") == 64_000)
        let cost = ModelPricing.estimatedCostUSD(model: "kurn-test-priced",
                                                 usage: AgentUsage(inputTokens: 1_000_000, outputTokens: 1_000_000))
        #expect(abs((cost ?? 0) - 10) < 1e-9)

        now = now.addingTimeInterval(60 * 60)
        #expect(await updater.refreshIfDue() == .notDue)
        #expect(fixture.calls.count == 1)

        now = now.addingTimeInterval(ModelCatalogUpdater.checkInterval)
        #expect(await updater.refreshIfDue() == .unchanged)
        #expect(fixture.calls.count == 2)

        // The next launch applies the saved copy without the network.
        ModelCatalogOverlay.install(nil)
        #expect(Self.updater(fixture).loadStored())
        #expect(ModelCatalogOverlay.current?.entry(for: "kurn-test-priced")?.contextTokens == 64_000)
        #expect(fixture.calls.count == 2)
    }

    @Test func anInvalidCatalogIsRefusedAndNotSaved() async throws {
        defer { ModelCatalogOverlay.install(nil) }
        ModelCatalogOverlay.install(nil)
        let fixture = try Self.fixture()
        let updater = Self.updater(fixture, response: { Data(#"{"format":"kurn.model-catalog","schema":2}"#.utf8) })
        #expect(await updater.refreshIfDue() == .rejected)
        #expect(ModelCatalogOverlay.current == nil)
        #expect(!Self.updater(fixture).loadStored())
        // A refused check still waits a day.
        #expect(await updater.refreshIfDue() == .notDue)
    }

    @Test func aFailedFetchKeepsTheBundledCatalogsAndWaitsADay() async throws {
        let fixture = try Self.fixture()
        let updater = Self.updater(fixture, response: { throw URLError(.notConnectedToInternet) })
        #expect(await updater.refreshIfDue() == .failed)
        #expect(await updater.refreshIfDue() == .notDue)
        #expect(fixture.calls.count == 1)
    }

    @Test func aCloudProviderWithAKeyCountsAsInUse() throws {
        let defaults = try #require(UserDefaults(suiteName: "ModelCatalogUpdaterTests-\(UUID().uuidString)"))
        let keychain = CatalogTestKeychain()
        let settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults,
                                   credentials: CredentialStore(keychain: keychain))
        settings.credentials.saveKey("sk-test", for: .openAI)
        settings.aiProviderID = AIProvider.openAI.id
        #expect(ModelCatalogUpdater.usesCloud(settings))
        settings.credentials.saveKey("", for: .openAI)
        #expect(!ModelCatalogUpdater.usesCloud(settings))
    }

    @Test func theCompositionAppliesTheSavedCatalogAtLaunch() throws {
        defer { ModelCatalogOverlay.install(nil) }
        let fixture = try Self.fixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try Self.document.write(to: fixture.directory.appendingPathComponent(ModelCatalogUpdater.fileName))
        let defaults = try #require(UserDefaults(suiteName: "ModelCatalogUpdaterTests-\(UUID().uuidString)"))
        let settings = AppSettings(cloudStore: InMemoryCloudKeyValueStore(), defaults: defaults,
                                   credentials: CredentialStore(keychain: CatalogTestKeychain()))
        ModelCatalogOverlay.install(nil)
        let composition = AppComposition(settings: settings, modelCatalog: Self.updater(fixture))
        #expect(ModelCatalogOverlay.current?.entry(for: "kurn-test-priced") != nil)
        #expect(composition.modelCatalog.apply(Self.document) == .unchanged)
        #expect(ModelCatalogUpdater.defaultDirectory()?.lastPathComponent == "ModelCatalog")
    }
}

/// A `KeychainAccessing` conformer with no Security-framework dependency.
private final class CatalogTestKeychain: KeychainAccessing, @unchecked Sendable {
    var storage: [String: String] = [:]

    func get(_ account: String) -> KeychainReadOutcome {
        storage[account].map { .found($0) } ?? .absent
    }

    @discardableResult
    func set(_ value: String, for account: String) -> KeychainWriteOutcome {
        storage[account] = value
        return .success
    }

    @discardableResult
    func delete(_ account: String) -> KeychainWriteOutcome {
        storage[account] = nil
        return .success
    }
}
