import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
struct KnowledgeSearchTests {
    private actor Embedder: TextEmbedding {
        nonisolated let modelIdentifier = "synthetic-local-v1"
        var count = 0
        let malformed: Bool
        let fails: Bool
        init(malformed: Bool = false, fails: Bool = false) { self.malformed = malformed; self.fails = fails }
        func embed(_ texts: [String]) async throws -> [[Float]] {
            count += 1
            if fails { throw FixtureError.unavailable }
            return malformed ? [[.nan]] : texts.map { _ in [1, 0] }
        }
    }
    @MainActor private final class Counter { var value = 0 }
    private enum FixtureError: Error { case unavailable }

    private func fixture(allowsEmbedding: Bool = false, policy: String = "policy-v1", name: String = "Example portal",
                         count: Int = 1) throws -> KnowledgeBrowserRead {
        let meeting = UUID()
        let entities = (0..<count).map { _ in KnowledgeWikiSnapshot.Entity(id: UUID(), kind: .project, name: name, aliases: ["Orion workspace"]) }
        let facts = entities.map { entity in
            KnowledgeWikiSnapshot.Fact(id: UUID(), subjectID: entity.id, predicate: .hasStatus, value: .enumeration("open"),
                qualifiers: .init(modality: .reported, polarity: .negative, claimKind: .internalStatusReport,
                    authority: .attributed, confidence: .low, review: .machineExtracted),
                source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "The portal budget was not approved.",
                        startMs: 0, endMs: 1_000, attributedSpeaker: "Example speaker")]))
        }
        return try KnowledgeBrowserRead(meetingIDs: [meeting], wiki: .init(revision: 1, entities: entities, facts: facts),
            meetingTitles: [meeting: "Example review"], policyRevisionKey: policy, allowsEmbedding: allowsEmbedding)
    }

    @Test func lexicalWorksWithSemanticOffAndNeverLoadsAModel() async throws {
        let read = try fixture(allowsEmbedding: true), embedder = Embedder()
        let hits = try await KnowledgeSearchService(embedder: embedder).search(query: "Orion", corpus: read.searchCorpus, useSemantic: false)
        #expect(hits.contains { $0.kind == .alias })
        #expect(await embedder.count == 0)
    }

    @Test func embeddingRequiresBothPolicyAndFreshAdmissionAuthorization() async throws {
        let denied = try fixture(), embedder = Embedder()
        let service = KnowledgeSearchService(embedder: embedder)
        _ = try await service.search(query: "portal", corpus: denied.searchCorpus, useSemantic: true,
            authorizeEmbedding: { Issue.record("Policy denied before admission"); return true })
        let allowed = try fixture(allowsEmbedding: true)
        #expect(try await service.search(query: "revenue", corpus: allowed.searchCorpus, useSemantic: true,
            authorizeEmbedding: { false }).isEmpty)
        #expect(await embedder.count == 0)
        #expect(try await !service.search(query: "revenue", corpus: allowed.searchCorpus, useSemantic: true,
            authorizeEmbedding: { true }).isEmpty)
        #expect(await embedder.count == 1)
    }

    @Test func unavailableMalformedAndOverBudgetDenseInputsFallBackToTheWholeLexicalCorpus() async throws {
        let read = try fixture(allowsEmbedding: true)
        for embedder in [Embedder(fails: true), Embedder(malformed: true)] {
            let hits = try await KnowledgeSearchService(embedder: embedder).search(query: "Orion", corpus: read.searchCorpus, useSemantic: true,
                authorizeEmbedding: { true })
            #expect(hits.contains { $0.kind == .alias })
        }
        let large = try fixture(allowsEmbedding: true, count: 50), embedder = Embedder()
        let hits = try await KnowledgeSearchService(embedder: embedder).search(query: "portal", corpus: large.searchCorpus, useSemantic: true,
            authorizeEmbedding: { Issue.record("Oversized dense corpus"); return true })
        #expect(hits.count == 40)
        #expect(await embedder.count == 0)
    }

    @Test func invalidAndEmptyQueriesDoNotRunEmbedding() async throws {
        let read = try fixture(allowsEmbedding: true), embedder = Embedder()
        let service = KnowledgeSearchService(embedder: embedder)
        #expect(try await service.search(query: "  ", corpus: read.searchCorpus, useSemantic: true).isEmpty)
        await #expect(throws: KnowledgeSearchError.invalidQuery) {
            try await service.search(query: String(repeating: "x", count: 257), corpus: read.searchCorpus, useSemantic: true)
        }
        #expect(await embedder.count == 0)
    }

    @Test func changedPolicyOrRevokedSourceNeverPublishesFinishedSearch() async throws {
        let before = try fixture(allowsEmbedding: true)
        let model = KnowledgeSearchViewModel()
        let counter = Counter()
        await model.search(query: "portal", meetingIDs: before.meetingIDs, useSemantic: false, isEnabled: { true }, reader: {
            counter.value += 1
            if counter.value > 1 { throw KnowledgeWikiStoreError.scopeDenied }
            return before
        }, searcher: { _, read, _, _ in try KnowledgeSearchIndex(pages: read.pages, meetingIDs: read.meetingIDs).search(query: "portal") })
        #expect(model.state == .unavailable)
        let entries = before.pages.flatMap { $0.sections.flatMap(\.entries) }
        let changed = try KnowledgeBrowserRead(meetingIDs: before.meetingIDs,
            wiki: .init(revision: 1, entities: before.pages.map(\.entity), facts: entries.map(\.fact)),
            meetingTitles: before.meetingTitles, policyRevisionKey: "policy-v2", allowsEmbedding: true)
        counter.value = 0
        await model.search(query: "portal", meetingIDs: before.meetingIDs, useSemantic: false, isEnabled: { true }, reader: {
            counter.value += 1; return counter.value == 1 ? before : changed
        }, searcher: { _, read, _, _ in try KnowledgeSearchIndex(pages: read.pages, meetingIDs: read.meetingIDs).search(query: "portal") })
        #expect(model.state == .unavailable)
    }

    @Test func disabledForeignAndMismatchedPresentationScopesAreMasked() async throws {
        let read = try fixture(), model = KnowledgeSearchViewModel()
        await model.search(query: "portal", meetingIDs: read.meetingIDs, useSemantic: false, isEnabled: { false }, reader: {
            Issue.record("Disabled reader"); return read
        })
        #expect(model.state == .idle)
        await model.search(query: String(repeating: "x", count: 257), meetingIDs: read.meetingIDs,
            useSemantic: false, isEnabled: { true }, reader: { Issue.record("Oversized query read"); return read })
        #expect(model.state == .limited)
        await model.search(query: "portal", meetingIDs: [UUID()], useSemantic: false, isEnabled: { true }, reader: { read },
            searcher: { _, _, _, _ in Issue.record("Foreign source set"); return [] })
        #expect(model.state == .unavailable)
        await model.search(query: "portal", meetingIDs: read.meetingIDs, useSemantic: false, isEnabled: { true }, reader: { read })
        guard case .loaded = model.state else { Issue.record("Lexical read unavailable"); return }
        #expect(model.presentation(query: "other", meetingIDs: read.meetingIDs) == .idle)
        #expect(model.presentation(query: "portal", meetingIDs: [UUID()]) == .idle)
    }

    @Test func forgedTypedDocumentsCannotPassFreshScopeValidation() async throws {
        let read = try fixture(), foreign = try fixture(name: "Private outside scope"), model = KnowledgeSearchViewModel()
        let hits = try KnowledgeSearchIndex(pages: foreign.pages, meetingIDs: foreign.meetingIDs).search(query: "Private")
        await model.search(query: "Private", meetingIDs: read.meetingIDs, useSemantic: false, isEnabled: { true }, reader: { read },
            searcher: { _, _, _, _ in hits })
        #expect(model.state == .unavailable)
    }

    @Test func cancelledAdmissionDoesNotStartTheModel() async throws {
        let read = try fixture(allowsEmbedding: true), embedder = Embedder(), gate = SearchGate()
        let service = KnowledgeSearchService(embedder: embedder)
        let task = Task {
            try await service.search(query: "portal", corpus: read.searchCorpus, useSemantic: true, authorizeEmbedding: {
                await gate.wait()
                try Task.checkCancellation()
                return true
            })
        }
        await gate.started()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; Issue.record("Cancelled search completed") }
        catch is CancellationError {} catch { Issue.record("Unexpected error") }
        #expect(await embedder.count == 0)
    }

    @Test func invalidatedSuspendedSearchCannotReplaceANewerQuery() async throws {
        let read = try fixture(), model = KnowledgeSearchViewModel()
        let gate = SearchGate()
        let old = Task { @MainActor in
            await model.search(query: "old", meetingIDs: read.meetingIDs, useSemantic: false, isEnabled: { true }, reader: { read },
                searcher: { _, _, _, _ in await gate.wait(); return [] })
        }
        await gate.started()
        await model.search(query: "Orion", meetingIDs: read.meetingIDs, useSemantic: false, isEnabled: { true }, reader: { read })
        let expected = model.state
        await gate.release()
        await old.value
        #expect(model.state == expected)
        guard case let .loaded(hits) = expected else { Issue.record("New query lost"); return }
        #expect(hits.contains { $0.kind == .alias })
    }
}

private actor SearchGate {
    var continuation: CheckedContinuation<Void, Never>?
    var startWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            startWaiters.forEach { $0.resume() }; startWaiters = []
        }
    }
    func started() async {
        if continuation != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
