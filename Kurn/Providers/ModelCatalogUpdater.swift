//
//  ModelCatalogUpdater.swift
//  Kurn
//
//  Keeps the remote model catalog (`ModelCatalogDocument`) current: reviewed context windows,
//  capabilities and list prices published in the repository between releases, applied over the
//  catalogs compiled into the app (`ModelCatalogOverlay`).
//
//  It reaches the network only when the person already sends content to a cloud model (the
//  selected summary/chat provider is a cloud vendor with a key), at most once a day, with a plain
//  GET that carries no header, key or content. The document is read strictly, and one that is
//  malformed, out of bounds, older than what the app knows, or dated in the future is ignored:
//  the bundled catalogs stay in force. It can change estimates only, never where anything is sent.
//

import AgentHarness
import Foundation

@MainActor
final class ModelCatalogUpdater {
    /// Served from the repository's default branch; the file is reviewed like any other change.
    static let sourceURL = URL(string: "https://raw.githubusercontent.com/carlosmazzei/Kurn/main/catalog/model-catalog-v1.json")!
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let lastCheckKey = "modelCatalog.lastCheckedAt"
    static let fileName = "model-catalog-v1.json"

    enum Outcome: String, Equatable {
        case noCloudProvider, notDue, busy, applied, unchanged, rejected, failed
    }

    typealias Fetch = @Sendable (URLRequest) async throws -> Data

    private let directory: URL?
    private let defaults: UserDefaults
    private let usesCloud: @MainActor () -> Bool
    private let fetch: Fetch
    private let now: () -> Date
    private var inFlight = false

    init(directory: URL? = ModelCatalogUpdater.defaultDirectory(), defaults: UserDefaults = .standard,
         usesCloud: @escaping @MainActor () -> Bool, fetch: @escaping Fetch = ModelCatalogUpdater.liveFetch,
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.defaults = defaults
        self.usesCloud = usesCloud
        self.fetch = fetch
        self.now = now
    }

    /// The selected summary/chat provider is a cloud vendor the person has given a key to.
    static func usesCloud(_ settings: AppSettings) -> Bool {
        let provider = settings.aiProvider
        return provider.kind != .appleOnDevice && settings.credentials.isUsable(provider)
    }

    /// Applies the document an earlier check saved, if it still validates. Launch only, no network.
    @discardableResult
    func loadStored() -> Bool {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let document = try? ModelCatalogDocument.decode(data) else { return false }
        return ModelCatalogOverlay.install(document, now: now())
    }

    /// Fetches and applies the published catalog when a cloud provider is in use and the last check
    /// is a day old. A failed or refused check also waits a day: the bundled catalogs are complete
    /// on their own.
    @discardableResult
    func refreshIfDue() async -> Outcome {
        guard !inFlight else { return .busy }
        guard usesCloud() else { return .noCloudProvider }
        let started = now()
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date {
            let age = started.timeIntervalSince(last)
            if age >= 0, age < Self.checkInterval { return .notDue }
        }
        inFlight = true
        defer { inFlight = false }
        defaults.set(started, forKey: Self.lastCheckKey)

        var request = URLRequest(url: Self.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        let outcome: Outcome
        do {
            let data = try await fetch(request)
            outcome = apply(data)
        } catch {
            AppLog.generation.atNotice.notice("model catalog: check failed code=\(error.publicLogCode, privacy: .public)")
            return .failed
        }
        let version = ModelCatalogOverlay.current?.version ?? "bundled"
        AppLog.generation.atNotice.notice("model catalog: \(outcome.rawValue, privacy: .public) version=\(version, privacy: .public)")
        return outcome
    }

    /// Validates and applies `data`, saving it only once it has been applied.
    func apply(_ data: Data) -> Outcome {
        guard let document = try? ModelCatalogDocument.decode(data) else { return .rejected }
        if ModelCatalogOverlay.current == document { return .unchanged }
        guard ModelCatalogOverlay.install(document, now: now()) else { return .rejected }
        save(data)
        return .applied
    }

    private var fileURL: URL? { directory?.appendingPathComponent(Self.fileName) }

    private func save(_ data: Data) {
        guard let directory, let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.generation.atError.error("model catalog: save failed code=\(error.publicLogCode, privacy: .public)")
        }
    }

    nonisolated static func defaultDirectory() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ModelCatalog", isDirectory: true)
    }

    /// One bounded GET through the app's transport: a 15-second deadline and a response no larger
    /// than the document may be.
    nonisolated static func liveFetch(_ request: URLRequest) async throws -> Data {
        let policy = HTTPPolicy(totalDeadline: 15, maxResponseBytes: ModelCatalogDocument.maxBytes)
        return try await LLMHTTP.sendValidated(request, session: .shared, policy: policy).0
    }
}
