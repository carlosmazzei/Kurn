import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension SwiftDataConcurrencySensitiveTests {
/// K2.8: deleting a source leaves nothing it exclusively supported, survives a
/// failed save or process death through its tombstone, and never touches what
/// another source supports.
@MainActor
struct KnowledgeDeletionTests {
    private actor Provider: LLMProvider {
        let provider = AIProvider.appleOnDevice
        func summarize(systemPrompt: String, userPrompt: String) async throws -> SummaryResult { SummaryResult(sections: []) }
        func chat(systemPrompt: String, messages: [ChatMessage], options: TextGenerationOptions) async throws -> String {
            let data = try #require(messages.first?.content.data(using: .utf8))
            let input = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let segments = try #require(input["segments"] as? [[String: Any]])
            let segment = try #require(segments.first)
            let id = try #require(segment["id"] as? String), quote = try #require(segment["text"] as? String)
            let wire: [String: Any] = ["version": 1,
                "entities": [["ref": "e1", "kind": "topic", "name": "Example topic", "aliases": []]],
                "assertions": [["ref": "a1", "subject": "e1", "predicate": "hasStatus", "value": ["type": "enum", "value": "open"],
                    "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
                    "confidence": "low", "attributedToSegmentID": id, "evidence": [["segmentIDs": [id], "quote": quote]]]],
                "events": [], "examinedSegmentIDs": segments.compactMap { $0["id"] as? String }]
            return String(decoding: try JSONSerialization.data(withJSONObject: wire), as: UTF8.self)
        }
    }

    private struct Fixture {
        let container: ModelContainer
        let meetings: [Meeting]
        let queue: KnowledgeJobQueue
        let compiler: KnowledgeCompilationCoordinator
        let management: KnowledgeSettingsCoordinator
        let deletion: KnowledgeDeletionCoordinator
    }

    private func fixture(meetings count: Int = 2) throws -> Fixture {
        let schema = KurnModelGraph.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.autosaveEnabled = false
        var meetings: [Meeting] = []
        for index in 0..<count {
            let meeting = Meeting(title: "Synthetic deletion \(index)")
            context.insert(meeting)
            let recording = Recording(meeting: meeting, fileName: "synthetic-deletion-\(index).m4a", duration: 2, transcriptionStatus: .done)
            context.insert(recording)
            let transcript = Transcript(recording: recording,
                segments: [.init(speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "Example topic \(index) is open.")], language: "en")
            context.insert(transcript); recording.transcript = transcript
            meetings.append(meeting)
        }
        try context.save()
        let defaults = try #require(UserDefaults(suiteName: "knowledge-deletion-\(UUID())"))
        let settings = AppSettings(defaults: defaults)
        settings.knowledgeEnabled = true
        let queue = KnowledgeJobQueue(container: container)
        let provider = Provider()
        let compiler = KnowledgeCompilationCoordinator(queue: queue, settings: settings,
            resolveProvider: { _, _ in provider }, isProviderUsable: { _ in true })
        return Fixture(container: container, meetings: meetings, queue: queue, compiler: compiler,
            management: KnowledgeSettingsCoordinator(compilation: compiler), deletion: KnowledgeDeletionCoordinator(queue: queue))
    }

    private func compiled(_ f: Fixture) async throws {
        for meeting in f.meetings {
            #expect(await f.compiler.compile(meetingID: meeting.id, trigger: .explicit) == .completed)
            try await f.management.rebuildPages(meetingIDs: [meeting.id])
        }
    }

    /// Deletes the meeting the way `MeetingLibrary` does: its tombstone in the same commit.
    private func delete(_ meeting: Meeting, in f: Fixture, scope: KnowledgeDeletionScope = .meeting) throws {
        let context = f.container.mainContext
        for tombstone in try KnowledgeDeletionRows.tombstones(for: [meeting.id], scope: scope, in: context) { context.insert(tombstone) }
        if scope == .meeting { context.delete(meeting) }
        try context.save()
    }

    private func entityIDs(of meetingID: UUID, in container: ModelContainer) throws -> Set<UUID> {
        let rows = try ModelContext(container).fetch(FetchDescriptor<KnowledgeAssertion>(predicate: #Predicate { $0.sourceMeetingID == meetingID }))
        return Set(rows.map(\.subjectEntityID))
    }

    private func count<Model: PersistentModel>(_ type: Model.Type, _ container: ModelContainer,
                                               where predicate: Predicate<Model>? = nil) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<Model>(predicate: predicate))
    }

    private func deletionCount(_ container: ModelContainer) throws -> Int {
        let kind = KnowledgeJobKind.deletion.rawValue
        return try count(KnowledgeJob.self, container, where: #Predicate { $0.kindRaw == kind })
    }

    @Test func deletingAMeetingLeavesNothingItExclusivelySupportedAndKeepsTheOtherSource() async throws {
        let f = try fixture()
        try await compiled(f)
        let (doomed, kept) = (f.meetings[0], f.meetings[1])
        let doomedID = doomed.id, keptID = kept.id
        let doomedEntities = try entityIDs(of: doomedID, in: f.container)
        let keptEntities = try entityIDs(of: keptID, in: f.container)
        let keptAssertions = try count(KnowledgeAssertion.self, f.container, where: #Predicate { $0.sourceMeetingID == keptID })
        #expect(!doomedEntities.isEmpty && doomedEntities.isDisjoint(with: keptEntities))
        #expect(try count(KnowledgeJob.self, f.container, where: #Predicate { $0.kindRaw == "projection" }) == 2)
        let before = try KnowledgeStoreRows.latestRevision(in: ModelContext(f.container))

        try delete(doomed, in: f)
        #expect(try deletionCount(f.container) == 1)
        f.deletion.drain(); await f.deletion.waitUntilIdle()

        #expect(try deletionCount(f.container) == 0)
        #expect(try count(KnowledgeAssertion.self, f.container, where: #Predicate { $0.sourceMeetingID == doomedID }) == 0)
        #expect(try count(KnowledgeEvidence.self, f.container, where: #Predicate { $0.meetingID == doomedID }) == 0)
        #expect(try count(KnowledgeEvent.self, f.container, where: #Predicate { $0.sourceMeetingID == doomedID }) == 0)
        #expect(try count(KnowledgeJob.self, f.container, where: #Predicate { $0.meetingID == doomedID }) == 0)
        let doomedList = Array(doomedEntities), keptList = Array(keptEntities)
        #expect(try count(KnowledgeEntity.self, f.container, where: #Predicate { doomedList.contains($0.id) }) == 0)
        #expect(try count(KnowledgeEntity.self, f.container, where: #Predicate { keptList.contains($0.id) }) == keptList.count)
        #expect(try count(KnowledgeAssertion.self, f.container, where: #Predicate { $0.sourceMeetingID == keptID }) == keptAssertions)
        // The page cache naming the deleted source is gone; the other one stays.
        #expect(try count(KnowledgeJob.self, f.container, where: #Predicate { $0.kindRaw == "projection" }) == 1)
        #expect(try KnowledgeStoreRows.latestRevision(in: ModelContext(f.container)) == before + 1)
        #expect(try await f.queue.writer().pendingProjection() == nil)
        #expect(f.deletion.lastFailureCode == nil)
        let read = try await f.compiler.readKnowledgeBrowser(meetingIDs: [keptID])
        #expect(!read.pages.isEmpty)
        // A pending tombstone no longer exists, so draining again changes nothing.
        f.deletion.drain(); await f.deletion.waitUntilIdle()
        #expect(try KnowledgeStoreRows.latestRevision(in: ModelContext(f.container)) == before + 1)
    }

    @Test func aFailedPurgeKeepsItsTombstoneAndEveryRowUntilTheRetry() async throws {
        struct Injected: Error {}
        let f = try fixture(meetings: 1)
        try await compiled(f)
        let meetingID = f.meetings[0].id
        let assertions = try count(KnowledgeAssertion.self, f.container, where: #Predicate { $0.sourceMeetingID == meetingID })
        try delete(f.meetings[0], in: f)
        let store = await f.queue.writer()
        await #expect(throws: Injected.self) { try await store.purgeNextDeletion(beforeSave: { throw Injected() }) }
        #expect(try deletionCount(f.container) == 1)
        #expect(try count(KnowledgeAssertion.self, f.container, where: #Predicate { $0.sourceMeetingID == meetingID }) == assertions)
        // The next opportunity (a launch, activation or save) resumes it.
        let receipt = try #require(try await store.purgeNextDeletion())
        #expect(receipt.scope == .meeting && receipt.meetingID == meetingID)
        #expect(try deletionCount(f.container) == 0)
        #expect(try count(KnowledgeAssertion.self, f.container) == 0)
        #expect(try count(KnowledgeEntity.self, f.container) == 0)
        #expect(try count(KnowledgeEvidence.self, f.container) == 0)
        #expect(try await store.purgeNextDeletion() == nil)
    }

    @Test func deletingARecordingPurgesTheMeetingsKnowledgeButKeepsItsContextAndAllowsRecompiling() async throws {
        let f = try fixture(meetings: 1)
        try await compiled(f)
        let meeting = f.meetings[0], meetingID = meeting.id
        let context = f.container.mainContext
        let occasion = KnowledgeContext(kind: .internalMeeting, name: "Synthetic occasion")
        context.insert(occasion)
        context.insert(SourceContextLink(meetingID: meetingID, contextID: occasion.id))
        try context.save()
        try delete(meeting, in: f, scope: .source)
        f.deletion.drain(); await f.deletion.waitUntilIdle()
        #expect(try count(KnowledgeAssertion.self, f.container, where: #Predicate { $0.sourceMeetingID == meetingID }) == 0)
        #expect(try count(SourceContextLink.self, f.container, where: #Predicate { $0.meetingID == meetingID }) == 1)
        #expect(try count(Meeting.self, f.container) == 1)
        // The remaining recordings can be compiled again; nothing replays the purged job.
        #expect(await f.compiler.compile(meetingID: meetingID, trigger: .explicit) == .completed)
        #expect(try count(KnowledgeAssertion.self, f.container, where: #Predicate { $0.sourceMeetingID == meetingID }) == 1)
    }

    @Test func aSurvivorMergedIntoADeletedIdentityStandsAloneAndAuditsNamingTheSourceGo() async throws {
        let f = try fixture(meetings: 2)
        try await compiled(f)
        let (doomed, kept) = (f.meetings[0], f.meetings[1])
        let target = try #require(try entityIDs(of: doomed.id, in: f.container).first)
        let survivor = try #require(try entityIDs(of: kept.id, in: f.container).first)
        let context = f.container.mainContext
        let keptID = kept.id
        let row = try #require(try context.fetch(FetchDescriptor<KnowledgeEntity>(predicate: #Predicate { $0.id == survivor })).first)
        row.mergedIntoID = target
        let unrelated = UUID()
        context.insert(KnowledgeReview(kind: .mergeCandidate, subjectIDsData: try JSONEncoder().encode([survivor, target])))
        context.insert(KnowledgeReview(kind: .conflict, subjectIDsData: try JSONEncoder().encode([unrelated])))
        try context.save()

        try delete(doomed, in: f)
        f.deletion.drain(); await f.deletion.waitUntilIdle()

        let fresh = ModelContext(f.container)
        let survivorRow = try #require(try fresh.fetch(FetchDescriptor<KnowledgeEntity>(predicate: #Predicate { $0.id == survivor })).first)
        #expect(survivorRow.mergedIntoID == nil)
        #expect(try fresh.fetchCount(FetchDescriptor<KnowledgeEntity>(predicate: #Predicate { $0.id == target })) == 0)
        let reviews = try fresh.fetch(FetchDescriptor<KnowledgeReview>())
        #expect(reviews.count == 1 && reviews.first?.kindRaw == KnowledgeReviewItemKind.conflict.rawValue)
        #expect(try count(KnowledgeAssertion.self, f.container, where: #Predicate { $0.sourceMeetingID == keptID }) == 1)
    }

    @Test func anUnreadablePageCacheCannotProveItExcludesTheSourceAndIsRemoved() async throws {
        let f = try fixture(meetings: 1)
        let context = f.container.mainContext
        let cache = KnowledgeJob(idempotencyKey: "knowledge-wiki-v1:unreadable", kind: .projection, pipelineVersion: "knowledge-wiki-v1")
        cache.stateRaw = KnowledgeJobState.succeeded.rawValue
        cache.checkpointData = Data("not a projection".utf8)
        context.insert(cache)
        let article = KnowledgeJob(idempotencyKey: "knowledge.article.v1:kept", kind: .meetingArticle, meetingID: UUID(), pipelineVersion: "wiki-v1")
        context.insert(article)
        try context.save()
        try delete(f.meetings[0], in: f)
        f.deletion.drain(); await f.deletion.waitUntilIdle()
        #expect(try count(KnowledgeJob.self, f.container, where: #Predicate { $0.kindRaw == "projection" }) == 0)
        // Another meeting's episodic article work is not canonical knowledge.
        #expect(try count(KnowledgeJob.self, f.container, where: #Predicate { $0.kindRaw == "meetingArticle" }) == 1)
    }

    @Test func deletingTheCorpusKeepsMeetingsArticlesAndContextsAndCanCompileAgain() async throws {
        let f = try fixture(meetings: 2)
        try await compiled(f)
        let context = f.container.mainContext
        let occasion = KnowledgeContext(kind: .internalMeeting, name: "Synthetic occasion")
        context.insert(occasion)
        context.insert(SourceContextLink(meetingID: f.meetings[0].id, contextID: occasion.id))
        context.insert(KnowledgeJob(idempotencyKey: "knowledge.article.v1:kept", kind: .meetingArticle,
            meetingID: f.meetings[1].id, pipelineVersion: "wiki-v1"))
        context.insert(KnowledgeReview(kind: .conflict, subjectIDsData: try JSONEncoder().encode([UUID()])))
        try context.save()
        let before = try KnowledgeStoreRows.latestRevision(in: ModelContext(f.container))

        try await f.deletion.deleteCorpus()

        for count in [try count(KnowledgeEntity.self, f.container), try count(KnowledgeAssertion.self, f.container),
                      try count(KnowledgeEvidence.self, f.container), try count(KnowledgeEvent.self, f.container),
                      try count(KnowledgeRelation.self, f.container), try count(KnowledgeReview.self, f.container),
                      try deletionCount(f.container)] { #expect(count == 0) }
        #expect(try count(KnowledgeJob.self, f.container, where: #Predicate { $0.kindRaw == "extraction" || $0.kindRaw == "projection" }) == 0)
        #expect(try count(KnowledgeJob.self, f.container, where: #Predicate { $0.kindRaw == "meetingArticle" }) == 1)
        #expect(try count(Meeting.self, f.container) == 2)
        #expect(try count(KnowledgeContext.self, f.container) == 1 && count(SourceContextLink.self, f.container) == 1)
        #expect(try KnowledgeStoreRows.latestRevision(in: ModelContext(f.container)) == before + 1)
        #expect(try await f.queue.writer().pendingProjection() == nil)
        #expect(!f.deletion.isDeletingCorpus)
        #expect(await f.compiler.compile(meetingID: f.meetings[1].id, trigger: .explicit) == .completed)
    }

    @Test func aTombstoneIsNotDuplicatedAndAnUnknownOneIsRefusedWithoutBeingDropped() async throws {
        let f = try fixture(meetings: 1)
        let context = f.container.mainContext
        let meetingID = f.meetings[0].id
        for tombstone in try KnowledgeDeletionRows.tombstones(for: [meetingID], scope: .source, in: context) { context.insert(tombstone) }
        try context.save()
        #expect(try KnowledgeDeletionRows.tombstones(for: [meetingID], scope: .source, in: context).isEmpty)
        #expect(try KnowledgeDeletionRows.tombstones(for: [meetingID], scope: .meeting, in: context).count == 1)
        let store = await f.queue.writer()
        #expect(try await store.pendingDeletionCount() == 1)
        let row = try #require(try context.fetch(FetchDescriptor<KnowledgeJob>()).first)
        row.strategyRaw = "future-scope"
        try context.save()
        await #expect(throws: KnowledgeStoreError.invalidJob) { try await store.purgeNextDeletion() }
        #expect(try deletionCount(f.container) == 1)
    }
}
}
