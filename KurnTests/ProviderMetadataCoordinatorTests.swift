import AgentHarness
import Foundation
import Synchronization
import Testing
@testable import Kurn

private actor MetadataGate {
    var started = 0
    var waitingForFour: CheckedContinuation<Void, Never>?
    var releases: [CheckedContinuation<Void, Never>] = []
    var opened = false
    func block() async -> AgentMetadataRefresh {
        if opened { return .failed }
        started += 1
        if started == 4 {
            waitingForFour?.resume()
            waitingForFour = nil
        }
        await withCheckedContinuation { releases.append($0) }
        return .fetched
    }
    func waitForFour() async {
        if started >= 4 || opened { return }
        await withCheckedContinuation { waitingForFour = $0 }
    }
    func open() {
        opened = true
        waitingForFour?.resume()
        waitingForFour = nil
        for release in releases { release.resume() }
        releases = []
    }
}

struct ProviderMetadataCoordinatorTests {
    @Test(.timeLimit(.minutes(1))) func concurrentLookupsAreBoundedWithoutBlockingTheExecutor() async {
        let coordinator = ProviderMetadataCoordinator()
        let gate = MetadataGate()
        let store = ModelContextWindowStore()
        let identity: @Sendable (String) -> ProviderMetadataCoordinator.Identity = { model in
            ProviderMetadataCoordinator.Identity(store: ObjectIdentifier(store), provider: "test", kind: .anthropic,
                                                   endpoint: "https://example.test", model: model, credential: "fixture")
        }
        async let first = coordinator.run(identity: identity("1")) { await gate.block() }
        async let second = coordinator.run(identity: identity("2")) { await gate.block() }
        async let third = coordinator.run(identity: identity("3")) { await gate.block() }
        async let fourth = coordinator.run(identity: identity("4")) { await gate.block() }
        await withTaskCancellationHandler { await gate.waitForFour() } onCancel: { Task { await gate.open() } }
        let fifth = await coordinator.run(identity: identity("5")) {
            Issue.record("Concurrency limit exceeded")
            return .failed
        }
        #expect(fifth == .deferred)
        await gate.open()
        let results = await [first, second, third, fourth]
        #expect(results.allSatisfy { $0 == .fetched })
    }

    @Test func retryDeadlineRecoversFromClockChanges() throws {
        let suite = "ProviderMetadataCoordinatorTests.clock.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let time = Mutex(Date())
        let store = ModelContextWindowStore(defaults: defaults, now: { time.withLock { $0 } })
        #expect(store.refreshIsDue(for: .anthropic, model: "alias"))
        store.recordRefresh(for: .anthropic, model: "alias")
        #expect(!store.refreshIsDue(for: .anthropic, model: "alias"))
        time.withLock { $0 = $0.addingTimeInterval(901) }
        #expect(store.refreshIsDue(for: .anthropic, model: "alias"))
        store.recordRefresh(for: .anthropic, model: "alias")
        time.withLock { $0 = $0.addingTimeInterval(-1_000) }
        #expect(store.refreshIsDue(for: .anthropic, model: "alias"))
    }
}
