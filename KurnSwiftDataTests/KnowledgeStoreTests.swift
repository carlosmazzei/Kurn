import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct KnowledgeStoreTests {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let meeting: Meeting
        let store: KnowledgeStore
        let auth: KnowledgeExtractionAuthorization
    }

    private func fixture(recordings count: Int = 1, storeURL: URL? = nil) throws -> Fixture {
        let schema = KurnModelGraph.schema
        let configuration = storeURL.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let meeting = Meeting(title: "Example planning")
        context.insert(meeting)
        for index in 0..<count {
            let recording = Recording(meeting: meeting, fileName: "synthetic-\(index).m4a", duration: 2)
            context.insert(recording)
            let transcript = Transcript(recording: recording, segments: [TranscriptSegment(
                speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "Example team owns Example portal.")], language: "en")
            context.insert(transcript)
            recording.transcript = transcript
        }
        try context.save()
        let policy = KnowledgeProcessingPolicy()
        let auth = KnowledgeExtractionAuthorization(featureEnabled: true, policies: [policy], sourceClassifications: [.internal])
        return Fixture(container: container, context: context, meeting: meeting, store: KnowledgeStore(modelContainer: container), auth: auth)
    }

    private func snapshot(_ fixture: Fixture, scope: String = "workspace") async throws -> KnowledgeStoreSnapshot {
        let auth = fixture.auth
        return try await fixture.store.snapshot(meetingID: fixture.meeting.id, scope: scope, provider: .appleOnDevice, authorization: { auth })
    }

    private func request(
        _ snapshot: KnowledgeStoreSnapshot, version: String = "extractor-v1", badQuote: Bool = false, covered: Bool = true, relational: Bool = true
    ) throws -> KnowledgeCommitRequest {
        let compilations = try snapshot.recordings.filter { !$0.segments.isEmpty }.map { source in
            let segment = try #require(source.segments.first)
            let anchor = segment.id.uuidString.lowercased()
            var wire: [String: Any] = [
                "version": 1,
                "entities": [["ref": "e1", "kind": "team", "name": "Example team", "aliases": []],
                             ["ref": "e2", "kind": "project", "name": "Example portal", "aliases": ["Portal"]]],
                "assertions": covered ? [["ref": "a1", "subject": "e1", "predicate": "owns", "object": "e2",
                    "modality": "agreed", "polarity": "positive", "claimKind": "commitment", "authorityStatus": "attributed",
                    "confidence": "high", "attributedToSegmentID": anchor,
                    "evidence": [["segmentIDs": [anchor], "quote": badQuote ? "Invented approval." : segment.text]]]] : [],
                "events": covered ? [["ref": "v1", "entity": "e1", "assertion": "a1", "kind": "created"]] : [],
                "examinedSegmentIDs": covered ? source.segments.map { $0.id.uuidString.lowercased() } : []
            ]
            if !relational {
                var assertion = try #require((wire["assertions"] as? [[String: Any]])?.first)
                assertion["predicate"] = "hasStatus"
                assertion.removeValue(forKey: "object")
                assertion["value"] = ["type": "enum", "value": "open"]
                assertion["validFrom"] = ["text": "2026-11", "precision": "month"]
                wire["assertions"] = [assertion]
                wire["events"] = [["ref": "v1", "entity": "e1", "assertion": "a1", "kind": "statusChanged",
                    "occurredAt": ["text": "2026-11-15", "precision": "day"]]]
            }
            // Deliberately bypass validation here: the store must revalidate,
            // even if a caller constructs Codable output by another path.
            let document = try JSONDecoder().decode(KnowledgeExtraction.self, from: JSONSerialization.data(withJSONObject: wire))
            let result = KnowledgeExtractionService.Result(transcriptFingerprint: try #require(source.fingerprint),
                strategy: .fullContext, passes: [document], examinedSegmentIDs: [anchor], targetedPassCount: 0)
            return try KnowledgeRecordingCompilation(recordingID: source.id, result: result)
        }
        return KnowledgeCommitRequest(snapshot: snapshot, extractorVersion: version, schemaVersion: 1, provider: .appleOnDevice, compilations: compilations)
    }

    private func commit(_ request: KnowledgeCommitRequest, fixture: Fixture) async throws -> KnowledgeCommitReceipt {
        let auth = fixture.auth
        return try await fixture.store.commit(request, authorization: { auth })
    }

    @Test func commitsTheCompleteGraphJobProvenanceAndOutboxTogether() async throws {
        let fixture = try fixture()
        let token = try await snapshot(fixture)
        let receipt = try await commit(request(token), fixture: fixture)
        #expect(receipt.number == 1)
        #expect(receipt.assertionCount == 1)
        #expect(receipt.projectionPending)
        #expect(!receipt.isReplay)
        let context = ModelContext(fixture.container)
        #expect(try context.fetchCount(FetchDescriptor<KnowledgeEntity>()) == 2)
        let assertion = try #require(context.fetch(FetchDescriptor<KnowledgeAssertion>()).first)
        let evidence = try #require(context.fetch(FetchDescriptor<KnowledgeEvidence>()).first)
        let relation = try #require(context.fetch(FetchDescriptor<KnowledgeRelation>()).first)
        let event = try #require(context.fetch(FetchDescriptor<KnowledgeEvent>()).first)
        let job = try #require(context.fetch(FetchDescriptor<KnowledgeJob>()).first)
        #expect(assertion.revisionID == receipt.revisionID)
        #expect(evidence.assertionID == assertion.id)
        #expect(evidence.recordingID == token.recordings[0].id)
        #expect(evidence.quoteHash == KnowledgeStoreRows.digest(Data(evidence.quote.utf8)))
        #expect(relation.assertionID == assertion.id)
        #expect(event.assertionID == assertion.id)
        #expect(job.stateRaw == "succeeded")
        let provenance = try JSONDecoder().decode(KnowledgeCommitProvenance.self, from: #require(job.checkpointData))
        #expect(provenance.recordings[0].passes[0].attributionAnchors[assertion.id.uuidString.lowercased()]
            == token.recordings[0].segments[0].id.uuidString.lowercased())
        let coverage = try JSONDecoder().decode([KnowledgeCommitProvenance.Coverage].self, from: #require(job.coverageData))
        #expect(coverage[0].recordingID == evidence.recordingID)
    }

    @Test func typedValuesAndStatedTemporalPrecisionArePersisted() async throws {
        let fixture = try fixture()
        _ = try await commit(request(snapshot(fixture), relational: false), fixture: fixture)
        let context = ModelContext(fixture.container)
        let assertion = try #require(context.fetch(FetchDescriptor<KnowledgeAssertion>()).first)
        #expect(assertion.validFromText == "2026-11")
        #expect(assertion.validFromPrecisionRaw == "month")
        let value = try JSONDecoder().decode(KnowledgeTypedValue.self, from: #require(assertion.valueData))
        #expect(value == .enumeration("open"))
        #expect(try context.fetchCount(FetchDescriptor<KnowledgeRelation>()) == 0)
        let event = try #require(context.fetch(FetchDescriptor<KnowledgeEvent>()).first)
        #expect(event.occurredAtText == "2026-11-15")
        #expect(event.occurredPrecisionRaw == "day")
    }

    @Test func concurrentRerunsAndANewWriterReuseTheDurableJob() async throws {
        let fixture = try fixture()
        let request = try await request(snapshot(fixture))
        let auth = fixture.auth
        let store = fixture.store
        async let first = store.commit(request, authorization: { auth })
        async let second = store.commit(request, authorization: { auth })
        let receipts = try await [first, second]
        #expect(receipts[0].revisionID == receipts[1].revisionID)
        #expect(receipts.filter(\.isReplay).count == 1)
        let reopened = KnowledgeStore(modelContainer: fixture.container)
        let replay = try await reopened.commit(request, authorization: { auth })
        #expect(replay.isReplay)
        #expect(replay.number == 1)
        let context = ModelContext(fixture.container)
        #expect(try context.fetchCount(FetchDescriptor<KnowledgeRevision>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<KnowledgeJob>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<KnowledgeAssertion>()) == 1)
    }

    @Test func unrelatedCommitInvalidatesTheCanonicalTokenButNotACompletedReplay() async throws {
        let fixture = try fixture()
        let original = try await request(snapshot(fixture))
        let other = try await request(snapshot(fixture, scope: "other"))
        _ = try await commit(original, fixture: fixture)
        await #expect(throws: KnowledgeStoreError.staleRevision) { try await commit(other, fixture: fixture) }
        let replay = try await commit(original, fixture: fixture)
        #expect(replay.isReplay)
        let refreshed = try await commit(request(snapshot(fixture, scope: "other")), fixture: fixture)
        #expect(refreshed.number == 2)
    }

    @Test func transcriptEditsAndNewRecordingsInvalidateTheSourceToken() async throws {
        for addRecording in [false, true] {
            let fixture = try fixture()
            let request = try await request(snapshot(fixture))
            if addRecording {
                fixture.context.insert(Recording(meeting: fixture.meeting, fileName: "new.m4a", duration: 1))
            } else {
                let transcript = try #require(fixture.meeting.recordings.first?.transcript)
                var segments = transcript.segments
                segments[0].text += " Revised."
                transcript.segments = segments
            }
            try fixture.context.save()
            await #expect(throws: KnowledgeStoreError.sourceChanged) { try await commit(request, fixture: fixture) }
            #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<KnowledgeRevision>()) == 0)
        }
    }

    @Test func deletedCorruptAndUnreadySourcesFailClosed() async throws {
        for mode in 0..<3 {
            let fixture = try fixture()
            let request = try await request(snapshot(fixture))
            let recording = try #require(fixture.meeting.recordings.first)
            if mode == 0 { fixture.context.delete(fixture.meeting) }
            if mode == 1 { recording.transcript?.segmentsData = Data("broken".utf8) }
            if mode == 2 { recording.captureStateRaw = RecordingCaptureState.recoveryNeeded.rawValue }
            try fixture.context.save()
            await #expect(throws: (any Error).self) { try await commit(request, fixture: fixture) }
            #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<KnowledgeJob>()) == 0)
        }
    }

    @Test func livePolicyAndConsentAreCheckedAgainAtCommit() async throws {
        let fixture = try fixture()
        let request = try await request(snapshot(fixture))
        var disabled = fixture.auth
        disabled.featureEnabled = false
        let disabledAuth = disabled
        await #expect(throws: KnowledgeStoreError.policyDenied) {
            try await fixture.store.commit(request, authorization: { disabledAuth })
        }
        var changed = fixture.auth
        changed.policies[0].revision += 1
        let changedAuth = changed
        await #expect(throws: KnowledgeStoreError.policyChanged) {
            try await fixture.store.commit(request, authorization: { changedAuth })
        }
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<KnowledgeRevision>()) == 0)
        _ = try await commit(request, fixture: fixture)
        let newToken = try await fixture.store.snapshot(meetingID: fixture.meeting.id, scope: "workspace",
            provider: .appleOnDevice, authorization: { changedAuth })
        await #expect(throws: KnowledgeStoreError.policyChanged) {
            try await fixture.store.commit(self.request(newToken), authorization: { changedAuth })
        }
    }

    @Test func invalidCitationsAndIncompleteCoverageNeverWriteCanonicalRows() async throws {
        let fixture = try fixture()
        let token = try await snapshot(fixture)
        await #expect(throws: KnowledgeExtractionError.invalidEvidence) { try await commit(request(token, badQuote: true), fixture: fixture) }
        await #expect(throws: KnowledgeStoreError.incompleteCoverage) { try await commit(request(token, covered: false), fixture: fixture) }
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<KnowledgeEntity>()) == 0)
        #expect(try ModelContext(fixture.container).fetchCount(FetchDescriptor<KnowledgeRevision>()) == 0)
    }

    @Test func everyRecordingIsRequiredAndPassReferencesStaySeparate() async throws {
        let fixture = try fixture(recordings: 2)
        let token = try await snapshot(fixture)
        let full = try request(token)
        let partial = KnowledgeCommitRequest(snapshot: token, extractorVersion: "v1", schemaVersion: 1,
            provider: .appleOnDevice, compilations: Array(full.compilations.prefix(1)))
        await #expect(throws: KnowledgeStoreError.invalidCompilation) { try await commit(partial, fixture: fixture) }
        let receipt = try await commit(full, fixture: fixture)
        #expect(receipt.assertionCount == 2)
        let context = ModelContext(fixture.container)
        let assertions = try context.fetch(FetchDescriptor<KnowledgeAssertion>())
        #expect(Set(assertions.map(\.subjectEntityID)).count == 2)
        #expect(try context.fetchCount(FetchDescriptor<KnowledgeEntity>()) == 4)
        #expect(Set(try context.fetch(FetchDescriptor<KnowledgeEvidence>()).compactMap(\.recordingID)).count == 2)
    }

    @Test func saveFailureRollsBackInsertionsRetractionsAndTheOutbox() async throws {
        struct DiskFull: Error {}
        let fixture = try fixture()
        _ = try await commit(request(snapshot(fixture)), fixture: fixture)
        let next = try await request(snapshot(fixture), version: "v2")
        let auth = fixture.auth
        await #expect(throws: DiskFull.self) {
            try await fixture.store.commit(next, authorization: { auth }, beforeSave: { throw DiskFull() })
        }
        let context = ModelContext(fixture.container)
        #expect(try context.fetchCount(FetchDescriptor<KnowledgeRevision>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<KnowledgeJob>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<KnowledgeEntity>()) == 2)
        #expect(try context.fetch(FetchDescriptor<KnowledgeAssertion>()).allSatisfy { $0.retractedAt == nil })
        let retried = try await commit(next, fixture: fixture)
        #expect(retried.number == 2)
    }

    @Test func replacementIsScopedAndTranscriptChangesInvalidateAllUnsupportedEvidence() async throws {
        let fixture = try fixture()
        _ = try await commit(request(snapshot(fixture)), fixture: fixture)
        _ = try await commit(request(snapshot(fixture, scope: "other")), fixture: fixture)
        _ = try await commit(request(snapshot(fixture), version: "v2"), fixture: fixture)
        var context = ModelContext(fixture.container)
        #expect(try context.fetch(FetchDescriptor<KnowledgeAssertion>()).filter { $0.retractedAt == nil }.count == 2)
        let transcript = try #require(fixture.meeting.recordings.first?.transcript)
        var segments = transcript.segments
        segments[0].text += " Revised."
        transcript.segments = segments
        try fixture.context.save()
        _ = try await commit(request(snapshot(fixture), version: "v2"), fixture: fixture)
        context = ModelContext(fixture.container)
        #expect(try context.fetch(FetchDescriptor<KnowledgeAssertion>()).filter { $0.retractedAt == nil }.count == 1)
        #expect(try context.fetch(FetchDescriptor<KnowledgeEvidence>()).filter(\.isAvailable).count == 1)
    }

    @Test func projectionOutboxSurvivesNewWriterAndRejectsStaleAcknowledgement() async throws {
        let fixture = try fixture()
        let first = try await commit(request(snapshot(fixture)), fixture: fixture)
        let reopened = KnowledgeStore(modelContainer: fixture.container)
        #expect(try await reopened.pendingProjection()?.revisionID == first.revisionID)
        let second = try await commit(request(snapshot(fixture), version: "v2"), fixture: fixture)
        await #expect(throws: KnowledgeStoreError.staleRevision) { try await reopened.acknowledgeProjection(upTo: 1) }
        #expect(try await reopened.pendingProjection()?.number == second.number)
        try await reopened.acknowledgeProjection(upTo: 2)
        #expect(try await fixture.store.pendingProjection() == nil)
        #expect(try ModelContext(fixture.container).fetch(FetchDescriptor<KnowledgeRevision>()).allSatisfy { !$0.projectionPending })
    }

    @Test func cancelledJobsAndUnsupportedSchemasCannotCommit() async throws {
        let fixture = try fixture()
        let token = try await snapshot(fixture)
        let original = try request(token)
        let identity = try KnowledgeCompilationIdentity(scope: token.scope, meetingID: token.meetingID,
            transcriptFingerprint: token.transcriptFingerprint, extractorVersion: original.extractorVersion)
        let job = KnowledgeJob(idempotencyKey: try identity.idempotencyKey(), kind: .extraction,
            meetingID: token.meetingID, pipelineVersion: original.extractorVersion)
        job.stateRaw = "cancelled"
        fixture.context.insert(job)
        try fixture.context.save()
        await #expect(throws: KnowledgeStoreError.cancelledJob) { try await commit(original, fixture: fixture) }
        let unsupported = KnowledgeCommitRequest(snapshot: token, extractorVersion: "v2", schemaVersion: 2,
            provider: .appleOnDevice, compilations: original.compilations)
        await #expect(throws: KnowledgeStoreError.invalidCompilation) { try await commit(unsupported, fixture: fixture) }
    }

    @Test func contextMetadataChangesInvalidateTheTokenAndDanglingLinksFailClosed() async throws {
        let fixture = try fixture()
        let occasion = KnowledgeContext(kind: .internalMeeting, name: "Example planning")
        fixture.context.insert(occasion)
        fixture.context.insert(SourceContextLink(meetingID: fixture.meeting.id, contextID: occasion.id))
        try fixture.context.save()
        let token = try await snapshot(fixture)
        #expect(token.contextID == occasion.id)
        let original = try request(token)
        occasion.kindRaw = "vendorDiscussion"
        try fixture.context.save()
        await #expect(throws: KnowledgeStoreError.sourceChanged) { try await commit(original, fixture: fixture) }
        fixture.context.delete(occasion)
        try fixture.context.save()
        await #expect(throws: KnowledgeStoreError.invalidContext) { try await snapshot(fixture) }
    }

    @Test func contextPoliciesCannotBeOmittedFromAuthorization() async throws {
        let fixture = try fixture()
        let occasion = KnowledgeContext(kind: .internalMeeting, name: "Example protected", policyID: UUID().uuidString)
        fixture.context.insert(occasion)
        fixture.context.insert(SourceContextLink(meetingID: fixture.meeting.id, contextID: occasion.id))
        try fixture.context.save()
        await #expect(throws: KnowledgeStoreError.policyDenied) { try await snapshot(fixture) }
        occasion.policyID = fixture.auth.policies[0].id.uuidString
        try fixture.context.save()
        let token = try await snapshot(fixture)
        _ = try await commit(request(token), fixture: fixture)
    }

    @Test func durableOutboxIsRecoveredAfterTheContainerIsReopened() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-store-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let expected: KnowledgeCommitReceipt
        do {
            let fixture = try fixture(storeURL: url)
            expected = try await commit(request(snapshot(fixture)), fixture: fixture)
        }
        let schema = KurnModelGraph.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        let writer = KnowledgeStore(modelContainer: container)
        let pending = try await writer.pendingProjection()
        #expect(pending?.revisionID == expected.revisionID)
        try await writer.acknowledgeProjection(upTo: expected.number)
        #expect(try await writer.pendingProjection() == nil)
    }

    @Test func emptyMeetingsDuplicateRecordingsAndAmbiguousContextsAreRejected() async throws {
        let empty = try fixture(recordings: 0)
        let emptyToken = try await snapshot(empty)
        await #expect(throws: KnowledgeStoreError.invalidCompilation) { try await commit(request(emptyToken), fixture: empty) }
        let fixture = try fixture()
        let original = try await request(snapshot(fixture))
        let duplicate = KnowledgeCommitRequest(snapshot: original.snapshot, extractorVersion: "v1", schemaVersion: 1,
            provider: .appleOnDevice, compilations: original.compilations + original.compilations)
        await #expect(throws: KnowledgeStoreError.invalidCompilation) { try await commit(duplicate, fixture: fixture) }
        for _ in 0..<2 {
            let occasion = KnowledgeContext(kind: .internalMeeting, name: "Example occasion")
            fixture.context.insert(occasion)
            fixture.context.insert(SourceContextLink(meetingID: fixture.meeting.id, contextID: occasion.id))
        }
        try fixture.context.save()
        await #expect(throws: KnowledgeStoreError.ambiguousContext) { try await snapshot(fixture) }
    }

}
}
