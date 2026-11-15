import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct KnowledgeWikiProjectionTests {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let meetings: [Meeting]
        let store: KnowledgeStore
        var auth: KnowledgeWikiAuthorization
        var ids: Set<UUID> { Set(meetings.map(\.id)) }
    }

    private func fixture(count: Int = 1) throws -> Fixture {
        let schema = KurnModelGraph.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let meetings = (0..<count).map { index in
            let meeting = Meeting(title: "Example planning \(index)")
            context.insert(meeting)
            let recording = Recording(meeting: meeting, fileName: "synthetic-\(index).m4a", duration: 2)
            context.insert(recording)
            let transcript = Transcript(recording: recording, segments: [TranscriptSegment(speakerLabel: "Speaker 1",
                startTime: 0, endTime: 2, text: "Example portal depends on Example service.")], language: "en")
            context.insert(transcript)
            recording.transcript = transcript
            return meeting
        }
        try context.save()
        return Fixture(container: container, context: context, meetings: meetings, store: KnowledgeStore(modelContainer: container),
            auth: KnowledgeWikiAuthorization(featureEnabled: true, meetingIDs: Set(meetings.map(\.id)),
                policies: [KnowledgeProcessingPolicy()], sourceClassifications: [.internal]))
    }

    private func compile(_ f: Fixture, meetingID: UUID? = nil, scope: String = "workspace", version: String = "synthetic-v1") async throws {
        let auth = f.auth.extraction
        let token = try await f.store.snapshot(meetingID: meetingID ?? f.meetings[0].id, scope: scope,
            provider: .appleOnDevice, authorization: { auth })
        let source = try #require(token.recordings.first)
        let segment = try #require(source.segments.first)
        let anchor = segment.id.uuidString.lowercased()
        let wire: [String: Any] = ["version": 1,
            "entities": [["ref": "e1", "kind": "project", "name": "Example portal", "aliases": ["Portal"]],
                         ["ref": "e2", "kind": "project", "name": "Example service", "aliases": []]],
            "assertions": [["ref": "a1", "subject": "e1", "predicate": "dependsOn", "object": "e2",
                "modality": "reported", "polarity": "negative", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
                "confidence": "medium", "attributedToSegmentID": anchor,
                "validFrom": ["text": "2026-11", "precision": "month"],
                "evidence": [["segmentIDs": [anchor], "quote": segment.text]]]],
            "events": [], "examinedSegmentIDs": [anchor]]
        let document = try JSONDecoder().decode(KnowledgeExtraction.self, from: JSONSerialization.data(withJSONObject: wire))
        let result = KnowledgeExtractionService.Result(transcriptFingerprint: try #require(source.fingerprint), strategy: .fullContext,
            passes: [document], examinedSegmentIDs: [anchor], targetedPassCount: 0)
        _ = try await f.store.commit(KnowledgeCommitRequest(snapshot: token, extractorVersion: version, schemaVersion: 1, provider: .appleOnDevice,
            compilations: [try KnowledgeRecordingCompilation(recordingID: source.id, result: result)]), authorization: { auth })
    }

    private func snapshot(_ f: Fixture, ids: Set<UUID>? = nil, scope: String = "workspace") async throws -> KnowledgeWikiProjectionSnapshot {
        let auth = f.auth
        return try await f.store.wikiProjectionSnapshot(meetingIDs: ids ?? f.ids, scope: scope, authorization: { auth })
    }

    private func publish(_ f: Fixture, snapshot: KnowledgeWikiProjectionSnapshot? = nil,
                         narratives: [KnowledgeWikiNarrative] = []) async throws -> KnowledgeWikiProjection {
        let token: KnowledgeWikiProjectionSnapshot
        if let snapshot { token = snapshot } else { token = try await self.snapshot(f) }
        let auth = f.auth
        return try await f.store.publishWikiProjection(token, narratives: narratives, authorization: { auth })
    }

    private func read(_ f: Fixture, ids: Set<UUID>? = nil) async throws -> KnowledgeWikiProjection? {
        let auth = f.auth
        return try await f.store.wikiProjection(meetingIDs: ids ?? f.ids, scope: "workspace", authorization: { auth })
    }

    private func projectionJob(_ context: ModelContext) throws -> KnowledgeJob {
        let kind = KnowledgeJobKind.projection.rawValue
        return try #require(context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw == kind })).first)
    }

    @Test func publishesEvidenceBackedPagesAtomicallyAndReadsAfterWriterRecreation() async throws {
        let f = try fixture()
        try await compile(f)
        let projection = try await publish(f)
        #expect(projection.pages.count == 2)
        #expect(projection.snapshot.facts.count == 1)
        let fact = try #require(projection.snapshot.facts.first)
        #expect(fact.qualifiers.polarity == .negative)
        #expect(fact.source.evidence.first?.attributedSpeaker == "Speaker 1")
        #expect(projection.pages[0].markdown.contains("evidence:"))
        #expect(try await f.store.pendingProjection() == nil)
        #expect(try await publish(f) == projection)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeJob>()) == 2)
        let reopened = KnowledgeStore(modelContainer: f.container)
        let auth = f.auth
        #expect(try await reopened.wikiProjection(meetingIDs: f.ids, scope: "workspace", authorization: { auth }) == projection)
        #expect(try await f.store.queuedJobs(kinds: [KnowledgeJobKind.projection.rawValue]).isEmpty)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeAssertion>()) == 1)
    }

    @Test func invalidNarrativeCannotReplaceAValidPageOrClearPendingWork() async throws {
        let f = try fixture()
        try await compile(f)
        let token = try await snapshot(f)
        let fact = try #require(token.wiki.facts.first)
        let good = KnowledgeWikiNarrative(entityID: fact.subjectID, paragraphs: [.init(text: "Reported dependency.", assertionIDs: [fact.id])])
        let valid = try await publish(f, snapshot: token, narratives: [good])
        let oldBytes = try projectionJob(ModelContext(f.container)).checkpointData
        let invalid = KnowledgeWikiNarrative(entityID: fact.subjectID, paragraphs: [.init(text: "Invented claim.", assertionIDs: [UUID()])])
        await #expect(throws: KnowledgeWikiProjectionError.invalidNarrative) { try await publish(f, snapshot: token, narratives: [invalid]) }
        #expect(try projectionJob(ModelContext(f.container)).checkpointData == oldBytes)
        #expect(try await read(f) == valid)
        try await compile(f, version: "synthetic-v2")
        await #expect(throws: KnowledgeWikiProjectionError.invalidNarrative) { try await publish(f, narratives: [invalid]) }
        #expect(try await f.store.pendingProjection()?.number == 2)
        #expect(try await read(f) == nil)
    }

    @Test func rollbackRetainsOutboxAndPreviousProjectionOnSaveFailure() async throws {
        let f = try fixture()
        try await compile(f)
        let token = try await snapshot(f)
        let auth = f.auth
        await #expect(throws: KnowledgeWikiStoreError.invalidCanonical) {
            try await f.store.publishWikiProjection(token, authorization: { auth }, beforeSave: { throw KnowledgeWikiStoreError.invalidCanonical })
        }
        #expect(try await read(f) == nil)
        #expect(try await f.store.pendingProjection()?.number == 1)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeJob>()) == 1)
        _ = try await publish(f)
        let previous = try projectionJob(ModelContext(f.container)).checkpointData
        try await compile(f, version: "synthetic-v2")
        let next = try await snapshot(f)
        await #expect(throws: KnowledgeWikiStoreError.invalidCanonical) {
            try await f.store.publishWikiProjection(next, authorization: { auth }, beforeSave: { throw KnowledgeWikiStoreError.invalidCanonical })
        }
        #expect(try projectionJob(ModelContext(f.container)).checkpointData == previous)
        #expect(try await f.store.pendingProjection()?.number == 2)
    }

    @Test func liveACLFlagOperationAndContextPolicyAreCheckedBeforeCacheReads() async throws {
        let f = try fixture()
        try await compile(f)
        _ = try await publish(f)
        for index in 0..<4 {
            var denied = f.auth
            if index == 0 { denied.meetingIDs = [] }
            if index == 1 { denied.featureEnabled = false }
            if index == 2 { denied.policies[0].allowedOperations.remove(.pageNarrative) }
            if index == 3 { denied.policies = [] }
            let auth = denied
            await #expect(throws: KnowledgeWikiStoreError.scopeDenied) {
                try await f.store.wikiProjection(meetingIDs: f.ids, scope: "workspace", authorization: { auth })
            }
            await #expect(throws: KnowledgeWikiStoreError.scopeDenied) {
                try await f.store.wikiProjectionSnapshot(meetingIDs: f.ids, scope: "workspace", authorization: { auth })
            }
        }
        let occasion = KnowledgeContext(kind: .internalMeeting, name: "Synthetic restricted context", classification: .restricted,
            policyID: UUID().uuidString)
        f.context.insert(occasion)
        f.context.insert(SourceContextLink(meetingID: f.meetings[0].id, contextID: occasion.id))
        try f.context.save()
        await #expect(throws: KnowledgeWikiStoreError.scopeDenied) { try await read(f) }
    }

    @Test func changedSourcePolicyOrCanonicalRevisionRejectsStalePublication() async throws {
        var f = try fixture()
        try await compile(f)
        let token = try await snapshot(f)
        _ = try await publish(f, snapshot: token)
        f.auth.policies[0].revision += 1
        await #expect(throws: KnowledgeWikiStoreError.staleSnapshot) { try await publish(f, snapshot: token) }
        #expect(try await read(f) == nil)
        #expect(try await snapshot(f).wiki.facts.isEmpty)
        f.auth.policies[0].revision -= 1
        let transcript = try #require(f.meetings[0].recordings.first?.transcript)
        var segments = transcript.segments
        segments[0].text += " Updated."
        transcript.segments = segments
        try f.context.save()
        await #expect(throws: KnowledgeWikiStoreError.staleSnapshot) { try await publish(f, snapshot: token) }
        #expect(try await read(f) == nil)
        #expect(try await snapshot(f).wiki.facts.isEmpty)
        try await compile(f, version: "synthetic-v2")
        await #expect(throws: KnowledgeWikiStoreError.staleSnapshot) { try await publish(f, snapshot: token) }
        #expect(try await snapshot(f).wiki.facts.count == 1)
    }

    @Test func partialScopeNeverAcknowledgesAnotherSourcesRevision() async throws {
        let f = try fixture(count: 2)
        try await compile(f, meetingID: f.meetings[0].id)
        let stale = try await snapshot(f)
        try await compile(f, meetingID: f.meetings[1].id)
        await #expect(throws: KnowledgeWikiStoreError.staleSnapshot) { try await publish(f, snapshot: stale) }
        let narrow = try await snapshot(f, ids: [f.meetings[0].id])
        let result = try await publish(f, snapshot: narrow)
        #expect(result.snapshot.facts.count == 1)
        #expect(try await f.store.pendingProjection()?.number == 2)
        let pending = try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeRevision>()).filter(\.projectionPending)
        #expect(pending.map(\.number) == [2])
        let full = try await publish(f)
        #expect(full.snapshot.facts.count == 2)
        #expect(try await f.store.pendingProjection() == nil)
        try await compile(f, meetingID: f.meetings[0].id, scope: "other")
        #expect(try await snapshot(f).wiki.facts.count == 2)
        _ = try await publish(f)
        #expect(try await f.store.pendingProjection()?.number == 3)
    }

    @Test func mergeAndUndoRebuildViewsAndAcknowledgeTheirAuditedRevisions() async throws {
        let f = try fixture()
        try await compile(f)
        let initial = try await publish(f)
        let fact = try #require(initial.snapshot.facts.first)
        let auth = KnowledgeEntityResolutionAuthorization(extraction: f.auth.extraction, meetingIDs: f.ids)
        let token = try await f.store.entityMutationSnapshot(meetingIDs: f.ids, scope: "workspace", authorization: { auth })
        let operation = UUID()
        _ = try await f.store.mergeEntities(.init(operationID: operation, sourceID: fact.subjectID,
            targetID: try #require(fact.objectID), snapshot: token), authorization: { auth })
        #expect(try await read(f) == nil)
        let merged = try await publish(f)
        #expect(merged.pages.count == 1)
        #expect(merged.pages[0].entity.aliases.contains("Example portal"))
        #expect(merged.snapshot.facts.first?.id == fact.id)
        #expect(try await f.store.pendingProjection() == nil)
        let undo = try await f.store.entityMutationSnapshot(meetingIDs: f.ids, scope: "workspace", authorization: { auth })
        _ = try await f.store.undoEntityMerge(operationID: operation, snapshot: undo, authorization: { auth })
        #expect(try await publish(f).pages.count == 2)
        #expect(try await f.store.pendingProjection() == nil)
    }

    @Test func restrictedRedirectTargetsDoNotLeakNamesIDsOrAliases() async throws {
        let f = try fixture(count: 2)
        try await compile(f, meetingID: f.meetings[0].id)
        try await compile(f, meetingID: f.meetings[1].id)
        let all = try await snapshot(f)
        let first = try #require(all.wiki.facts.first { $0.source.meetingID == f.meetings[0].id })
        let second = try #require(all.wiki.facts.first { $0.source.meetingID == f.meetings[1].id })
        let auth = KnowledgeEntityResolutionAuthorization(extraction: f.auth.extraction, meetingIDs: f.ids)
        let token = try await f.store.entityMutationSnapshot(meetingIDs: f.ids, scope: "workspace", authorization: { auth })
        _ = try await f.store.mergeEntities(.init(operationID: UUID(), sourceID: first.subjectID, targetID: second.subjectID,
            snapshot: token), authorization: { auth })
        let selected = try await snapshot(f, ids: [f.meetings[0].id])
        #expect(selected.wiki.entities.isEmpty)
        #expect(selected.wiki.facts.isEmpty)
        let published = try await publish(f, snapshot: selected)
        #expect(published.pages.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(published), as: UTF8.self).contains(second.subjectID.uuidString))
        #expect(try await f.store.pendingProjection()?.number == 3)
    }

    @Test func corruptedEvidenceOrFutureProjectionCannotOverwriteValidBytes() async throws {
        for future in [false, true] {
            let f = try fixture()
            try await compile(f)
            let token = try await snapshot(f)
            _ = try await publish(f, snapshot: token)
            let context = ModelContext(f.container)
            let job = try projectionJob(context)
            let original = try #require(job.checkpointData)
            if future {
                var envelope = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
                envelope["version"] = 999
                job.checkpointData = try JSONSerialization.data(withJSONObject: envelope)
                try context.save()
                await #expect(throws: KnowledgeWikiStoreError.unsupportedProjection) { try await read(f) }
                await #expect(throws: KnowledgeWikiStoreError.unsupportedProjection) { try await publish(f, snapshot: token) }
                #expect(try projectionJob(ModelContext(f.container)).checkpointData == job.checkpointData)
            } else {
                let evidence = try #require(context.fetch(FetchDescriptor<KnowledgeEvidence>()).first)
                evidence.quote = "Invented quote."
                try context.save()
                await #expect(throws: KnowledgeWikiStoreError.invalidCanonical) { try await read(f) }
                await #expect(throws: KnowledgeWikiStoreError.invalidCanonical) { try await publish(f, snapshot: token) }
                #expect(try projectionJob(ModelContext(f.container)).checkpointData == original)
            }
        }
    }

    @Test func unavailableOrRejectedClaimsDoNotBecomePagesAndEmptyProjectionIsValid() async throws {
        let f = try fixture()
        #expect(try await read(f) == nil)
        #expect(try await publish(f).pages.isEmpty)
        try await compile(f)
        let context = ModelContext(f.container)
        let assertion = try #require(context.fetch(FetchDescriptor<KnowledgeAssertion>()).first)
        assertion.authorityStatusRaw = KnowledgeAuthorityStatus.rejected.rawValue
        try context.save()
        #expect(try await snapshot(f).wiki.facts.isEmpty)
        assertion.authorityStatusRaw = KnowledgeAuthorityStatus.attributed.rawValue
        let evidence = try #require(context.fetch(FetchDescriptor<KnowledgeEvidence>()).first)
        evidence.isAvailable = false
        try context.save()
        #expect(try await publish(f).pages.isEmpty)
    }
}
}
