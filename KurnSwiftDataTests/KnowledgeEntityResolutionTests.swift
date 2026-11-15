import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct KnowledgeEntityResolutionTests {
    private struct Fixture {
        let container: ModelContainer
        let store: KnowledgeStore
        let meetings: [Meeting]
        let auth: KnowledgeExtractionAuthorization
        let requests: [KnowledgeCommitRequest]
    }

    private func fixture(names: [String] = ["Example Portal"], copies: Int = 1,
                         kind: KnowledgeEntityKind = .project, scopes: [String]? = nil) async throws -> Fixture {
        let schema = KurnModelGraph.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = container.mainContext
        context.autosaveEnabled = false
        var meetings: [Meeting] = []
        for name in names {
            let meeting = Meeting(title: "Example identity review")
            context.insert(meeting)
            let recording = Recording(meeting: meeting, fileName: "synthetic-\(UUID()).m4a", duration: 2, transcriptionStatus: .done)
            context.insert(recording)
            let transcript = Transcript(recording: recording,
                segments: [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "\(name) is open.")], language: "en")
            context.insert(transcript)
            recording.transcript = transcript
            meetings.append(meeting)
        }
        try context.save()
        let store = KnowledgeStore(modelContainer: container)
        let auth = KnowledgeExtractionAuthorization(featureEnabled: true, policies: [.defaultDeny()], sourceClassifications: [.internal])
        var requests: [KnowledgeCommitRequest] = []
        for (index, meeting) in meetings.enumerated() {
            let token = try await store.snapshot(meetingID: meeting.id, scope: scopes?[index] ?? "workspace", provider: .appleOnDevice, authorization: { auth })
            let request = try request(token, name: names[index], copies: copies, kind: kind)
            _ = try await store.commit(request, authorization: { auth })
            requests.append(request)
        }
        return Fixture(container: container, store: store, meetings: meetings, auth: auth, requests: requests)
    }

    private func request(_ token: KnowledgeStoreSnapshot, name: String, copies: Int,
                         kind: KnowledgeEntityKind, version: String = "identity-fixture-v1") throws -> KnowledgeCommitRequest {
        let source = try #require(token.recordings.first)
        let segment = try #require(source.segments.first)
        let anchor = segment.id.uuidString.lowercased()
        let entities: [[String: Any]] = (0..<copies).map { ["ref": "e\($0)", "kind": kind.rawValue, "name": name, "aliases": []] }
        let assertions: [[String: Any]] = (0..<copies).map { index in
            ["ref": "a\(index)", "subject": "e\(index)", "predicate": "hasStatus", "value": ["type": "enum", "value": "open"],
             "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
             "confidence": "low", "attributedToSegmentID": anchor, "evidence": [["segmentIDs": [anchor], "quote": segment.text]]]
        }
        let wire: [String: Any] = ["version": 1, "entities": entities, "assertions": assertions, "events": [], "examinedSegmentIDs": [anchor]]
        let bytes = try JSONSerialization.data(withJSONObject: wire)
        let document = try KnowledgeExtraction.decode(bytes, segments: KnowledgeTranscriptSnapshot(segments: source.segments, language: source.language).sourceSegments)
        let fingerprint = try #require(source.fingerprint)
        let result = KnowledgeExtractionService.Result(transcriptFingerprint: fingerprint, strategy: .fullContext,
            passes: [document], examinedSegmentIDs: [anchor], targetedPassCount: 0)
        return KnowledgeCommitRequest(snapshot: token, extractorVersion: version, schemaVersion: 1, provider: .appleOnDevice,
            compilations: [try KnowledgeRecordingCompilation(recordingID: source.id, result: result)])
    }

    private func authorization(_ f: Fixture, indices: [Int]? = nil) -> KnowledgeEntityResolutionAuthorization {
        KnowledgeEntityResolutionAuthorization(extraction: f.auth,
            meetingIDs: Set((indices ?? Array(f.meetings.indices)).map { f.meetings[$0].id }))
    }

    private func snapshot(_ f: Fixture, indices: [Int]? = nil, scope: String = "workspace") async throws -> KnowledgeEntityResolutionSnapshot {
        let auth = authorization(f, indices: indices)
        return try await f.store.entityResolutionSnapshot(meetingIDs: auth.meetingIDs, scope: scope, authorization: { auth })
    }

    private func entityIDs(_ f: Fixture) throws -> [UUID] {
        let read = ModelContext(f.container)
        return try f.meetings.map { meeting in
            let id = meeting.id
            let rows = try read.fetch(FetchDescriptor<KnowledgeAssertion>(predicate: #Predicate { $0.sourceMeetingID == id }))
            return try #require(rows.first).subjectEntityID
        }
    }

    @Test func duplicatePeopleCreateReviewCandidatesWithoutLinkingOrChangingFacts() async throws {
        let f = try await fixture(names: ["Example Alex"], copies: 2, kind: .person)
        let read = ModelContext(f.container)
        let entities = try read.fetch(FetchDescriptor<KnowledgeEntity>())
        #expect(entities.count == 2)
        #expect(entities.allSatisfy { $0.mergedIntoID == nil })
        let assertions = try read.fetch(FetchDescriptor<KnowledgeAssertion>())
        #expect(Set(assertions.map(\.subjectEntityID)).count == 2)
        let review = try #require(read.fetch(FetchDescriptor<KnowledgeReview>()).first)
        let payload = try KnowledgeEntityResolutionRows.reviewPayload(review)
        #expect(payload.candidate?.match.exactName == true)
        #expect(payload.candidate?.match.requiresHumanReview == true)
        #expect(review.stateRaw == "open")
        let job = try #require(read.fetch(FetchDescriptor<KnowledgeJob>()).first)
        let bytes = try #require(job.checkpointData)
        let provenance = try #require(JSONStorage.decodeAuthoritative(KnowledgeCommitProvenance.self, from: bytes).decodedValue)
        #expect(provenance.resolutionSummary?.reviewCount == 1)
        let auth = f.auth
        let replay = try await f.store.commit(f.requests[0], authorization: { auth })
        #expect(replay.isReplay)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeReview>()) == 1)
    }

    @Test func manualMergeAndUndoAreIdempotentAndLeaveAssertionEvidenceIDsUnchanged() async throws {
        let f = try await fixture(names: ["Example Portal", "Example Platform"])
        let ids = try entityIDs(f)
        let access = authorization(f)
        let before = try await snapshot(f)
        let read = ModelContext(f.container)
        let assertionIDs = Set(try read.fetch(FetchDescriptor<KnowledgeAssertion>()).map(\.id))
        let evidenceIDs = Set(try read.fetch(FetchDescriptor<KnowledgeEvidence>()).map(\.id))
        let request = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[0], targetID: ids[1], snapshot: before)
        let applied = try await f.store.mergeEntities(request, authorization: { access })
        #expect(try await f.store.mergeEntities(request, authorization: { access }) == applied)
        let merged = try await snapshot(f)
        #expect(try KnowledgeEntityRedirectGraph.resolve(ids[0], nodes: merged.redirects) == ids[1])
        #expect(merged.entities.first?.aliases.contains("Example Portal") == true)
        let undone = try await f.store.undoEntityMerge(operationID: request.operationID, snapshot: merged, authorization: { access })
        #expect(undone.isUndo)
        #expect(try await f.store.undoEntityMerge(operationID: request.operationID, snapshot: merged, authorization: { access }) == undone)
        let after = try await snapshot(f)
        #expect(after.redirects[ids[0]]?.targetID == nil)
        let current = ModelContext(f.container)
        #expect(Set(try current.fetch(FetchDescriptor<KnowledgeAssertion>()).map(\.id)) == assertionIDs)
        #expect(Set(try current.fetch(FetchDescriptor<KnowledgeEvidence>()).map(\.id)) == evidenceIDs)
        #expect(try current.fetch(FetchDescriptor<KnowledgeAssertion>()).allSatisfy { $0.retractedAt == nil })
        #expect(try await f.store.pendingProjection()?.number == undone.revision)
        await #expect(throws: KnowledgeEntityStoreError.operationUndone) { try await f.store.mergeEntities(request, authorization: { access }) }
        let auth = f.auth
        #expect(try await f.store.commit(f.requests[0], authorization: { auth }).isReplay)
    }

    @Test func explicitSourceACLAndCompilationScopePreventCrossScopeMerges() async throws {
        let f = try await fixture(names: ["Example One", "Example Two"], scopes: ["workspace", "other"])
        let ids = try entityIDs(f)
        let access = authorization(f)
        let before = try await snapshot(f)
        #expect(before.entities.map(\.id) == [ids[0]])
        let request = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[0], targetID: ids[1], snapshot: before)
        await #expect(throws: KnowledgeEntityStoreError.scopeDenied) { try await f.store.mergeEntities(request, authorization: { access }) }
        let narrowed = authorization(f, indices: [0])
        await #expect(throws: KnowledgeEntityStoreError.scopeDenied) {
            try await f.store.entityResolutionSnapshot(meetingIDs: access.meetingIDs, scope: "workspace", authorization: { narrowed })
        }
        var disabled = f.auth
        disabled.featureEnabled = false
        let revoked = KnowledgeEntityResolutionAuthorization(extraction: disabled, meetingIDs: access.meetingIDs)
        await #expect(throws: KnowledgeEntityStoreError.scopeDenied) { try await f.store.mergeEntities(request, authorization: { revoked }) }
    }

    @Test func chainsRequireEveryAffectedOriginAndRestrictedReadsDoNotExposeRedirectTargets() async throws {
        let f = try await fixture(names: ["Example Private Alias", "Example Middle", "Example Root"])
        let ids = try entityIDs(f)
        let access = authorization(f)
        let first = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[0], targetID: ids[1], snapshot: try await snapshot(f))
        _ = try await f.store.mergeEntities(first, authorization: { access })
        let narrowed = authorization(f, indices: [1, 2])
        let narrowSnapshot = try await snapshot(f, indices: [1, 2])
        let denied = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[1], targetID: ids[2], snapshot: narrowSnapshot)
        await #expect(throws: KnowledgeEntityStoreError.scopeDenied) { try await f.store.mergeEntities(denied, authorization: { narrowed }) }
        let second = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[1], targetID: ids[2], snapshot: try await snapshot(f))
        _ = try await f.store.mergeEntities(second, authorization: { access })
        let full = try await snapshot(f)
        #expect(full.redirects[ids[0]]?.targetID == ids[1])
        #expect(try KnowledgeEntityRedirectGraph.resolve(ids[0], nodes: full.redirects) == ids[2])
        let restricted = try await snapshot(f, indices: [0])
        #expect(restricted.entities.isEmpty)
        #expect(restricted.redirects.isEmpty)
        #expect(restricted.isTruncated)
        let rootOnly = try await snapshot(f, indices: [2])
        #expect(rootOnly.entities.first?.aliases.isEmpty == true)
        let cycle = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[2], targetID: ids[0], snapshot: full)
        await #expect(throws: KnowledgeEntityResolutionError.redirectCycle) { try await f.store.mergeEntities(cycle, authorization: { access }) }
        let deniedUndo = try await snapshot(f, indices: [1, 2])
        await #expect(throws: KnowledgeEntityStoreError.scopeDenied) {
            try await f.store.undoEntityMerge(operationID: second.operationID, snapshot: deniedUndo, authorization: { narrowed })
        }
        _ = try await f.store.undoEntityMerge(operationID: second.operationID, snapshot: full, authorization: { access })
        let restored = try await snapshot(f)
        #expect(try KnowledgeEntityRedirectGraph.resolve(ids[0], nodes: restored.redirects) == ids[1])
    }

    @Test func reviewResolutionAndUndoShareTheRedirectTransactionAndRollbackOnFailure() async throws {
        let f = try await fixture(copies: 2)
        let access = authorization(f)
        let read = ModelContext(f.container)
        let candidate = try #require(read.fetch(FetchDescriptor<KnowledgeReview>()).first)
        let payload = try KnowledgeEntityResolutionRows.reviewPayload(candidate)
        let detail = try #require(payload.candidate)
        let before = try await snapshot(f)
        let request = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: detail.sourceID, targetID: detail.match.entityID,
            snapshot: before, candidateReviewID: candidate.id)
        await #expect(throws: KnowledgeStoreError.invalidCompilation) {
            try await f.store.mergeEntities(request, authorization: { access }, beforeSave: { throw KnowledgeStoreError.invalidCompilation })
        }
        #expect(try await snapshot(f).revision == before.revision)
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeEntity>()).allSatisfy { $0.mergedIntoID == nil })
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeReview>()) == 1)
        _ = try await f.store.mergeEntities(request, authorization: { access })
        let fresh = try await snapshot(f)
        await #expect(throws: KnowledgeStoreError.invalidCompilation) {
            try await f.store.undoEntityMerge(operationID: request.operationID, snapshot: fresh, authorization: { access },
                beforeSave: { throw KnowledgeStoreError.invalidCompilation })
        }
        #expect(try await snapshot(f).revision == fresh.revision)
        _ = try await f.store.undoEntityMerge(operationID: request.operationID, snapshot: fresh, authorization: { access })
        let current = ModelContext(f.container)
        let reopened = try #require(current.fetch(FetchDescriptor<KnowledgeReview>()).first { $0.id == candidate.id })
        #expect(reopened.stateRaw == "open")
        #expect(try KnowledgeEntityResolutionRows.reviewPayload(reopened).resolvedByOperationID == nil)
    }

    @Test func staleSourceAndCanonicalSnapshotsNeverApplyAHumanDecision() async throws {
        let f = try await fixture(names: ["Example A", "Example B", "Example C"])
        let ids = try entityIDs(f)
        let access = authorization(f)
        let before = try await snapshot(f)
        let first = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[0], targetID: ids[1], snapshot: before)
        _ = try await f.store.mergeEntities(first, authorization: { access })
        let stale = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[2], targetID: ids[1], snapshot: before)
        await #expect(throws: KnowledgeEntityStoreError.staleSnapshot) { try await f.store.mergeEntities(stale, authorization: { access }) }
        let fresh = try await snapshot(f)
        let transcript = try #require(f.meetings[2].recordings.first?.transcript)
        transcript.segments = [TranscriptSegment(speakerLabel: "Speaker 1", startTime: 0, endTime: 2, text: "Example corrected source.")]
        try f.container.mainContext.save()
        let changed = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[2], targetID: ids[1], snapshot: fresh)
        await #expect(throws: KnowledgeEntityStoreError.staleSnapshot) { try await f.store.mergeEntities(changed, authorization: { access }) }
    }

    @Test func futureAuditPayloadIsPreservedAndUndoUsesCurrentLivePolicy() async throws {
        let f = try await fixture(names: ["Example A", "Example B"])
        let ids = try entityIDs(f)
        let access = authorization(f)
        let request = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[0], targetID: ids[1], snapshot: try await snapshot(f))
        _ = try await f.store.mergeEntities(request, authorization: { access })
        let after = try await snapshot(f)
        let context = ModelContext(f.container)
        let row = try #require(context.fetch(FetchDescriptor<KnowledgeReview>()).first { $0.id == request.operationID })
        let original = try #require(row.payloadData)
        var payload = try KnowledgeEntityResolutionRows.reviewPayload(row)
        payload.version = 999
        let future = try KnowledgeStoreRows.authoritativeData(payload)
        row.payloadData = future
        try context.save()
        await #expect(throws: KnowledgeEntityStoreError.unsupportedPayload) {
            try await f.store.undoEntityMerge(operationID: request.operationID, snapshot: after, authorization: { access })
        }
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeReview>()).first { $0.id == request.operationID }?.payloadData == future)
        row.payloadData = original
        try context.save()
        var auth = f.auth
        auth.policies[0].revision += 1
        let renewed = KnowledgeEntityResolutionAuthorization(extraction: auth, meetingIDs: access.meetingIDs)
        let now = try await f.store.entityResolutionSnapshot(meetingIDs: renewed.meetingIDs, scope: "workspace", authorization: { renewed })
        #expect(now.entities.isEmpty) // Old-policy names are not offered as current candidates.
        let undone = try await f.store.undoEntityMerge(operationID: request.operationID, snapshot: now, authorization: { renewed })
        #expect(undone.isUndo)
        let read = ModelContext(f.container)
        #expect(try read.fetch(FetchDescriptor<KnowledgeEntity>()).allSatisfy { $0.mergedIntoID == nil })
    }
    @Test func candidateLimitsAreRecordedAndFailedCompilationRollsBackSuggestionsAndRetractions() async throws {
        let f = try await fixture(copies: 32)
        let read = ModelContext(f.container)
        #expect(try read.fetchCount(FetchDescriptor<KnowledgeReview>()) == KnowledgeEntityResolutionRows.reviewLimit)
        let job = try #require(read.fetch(FetchDescriptor<KnowledgeJob>()).first)
        let bytes = try #require(job.checkpointData)
        let provenance = try #require(JSONStorage.decodeAuthoritative(KnowledgeCommitProvenance.self, from: bytes).decodedValue)
        #expect(provenance.resolutionSummary?.reviewLimitReached == true)
        let auth = f.auth
        let token = try await f.store.snapshot(meetingID: f.meetings[0].id, scope: "workspace", provider: .appleOnDevice, authorization: { auth })
        let next = try request(token, name: "Example Portal", copies: 32, kind: .project, version: "identity-fixture-v2")
        await #expect(throws: KnowledgeStoreError.invalidCompilation) {
            try await f.store.commit(next, authorization: { auth }, beforeSave: { throw KnowledgeStoreError.invalidCompilation })
        }
        let after = ModelContext(f.container)
        #expect(try after.fetchCount(FetchDescriptor<KnowledgeReview>()) == KnowledgeEntityResolutionRows.reviewLimit)
        #expect(try after.fetchCount(FetchDescriptor<KnowledgeEntity>()) == 32)
        #expect(try after.fetch(FetchDescriptor<KnowledgeAssertion>()).allSatisfy { $0.retractedAt == nil })
    }

    @Test func futureCompilationIdentityCannotBeSilentlyTreatedAsAnEmptyCandidatePool() async throws {
        let f = try await fixture()
        let context = ModelContext(f.container)
        let job = try #require(context.fetch(FetchDescriptor<KnowledgeJob>()).first)
        let original = try #require(job.checkpointData)
        job.idempotencyKey = "knowledge.compile.v999:future"
        try context.save()
        await #expect(throws: KnowledgeEntityStoreError.unsupportedPayload) { try await snapshot(f) }
        let after = ModelContext(f.container)
        #expect(try after.fetch(FetchDescriptor<KnowledgeJob>()).first?.checkpointData == original)
        #expect(try after.fetch(FetchDescriptor<KnowledgeEntity>()).allSatisfy { $0.mergedIntoID == nil })
    }

    @Test func persistenceFailuresEmitSafeIdentityEventsAndScopeRefusalsDoNot() async throws {
        let f = try await fixture(names: ["Example A", "Example B"])
        let ids = try entityIDs(f)
        let access = authorization(f)
        let request = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[0], targetID: ids[1], snapshot: try await snapshot(f))
        let capture = EntityMutationEventCapture()
        ReliabilityLog.handler = { capture.record($0) }
        defer { ReliabilityLog.handler = nil }
        await #expect(throws: AppError.self) {
            try await f.store.mergeEntities(request, authorization: { access },
                beforeSave: { throw AppError.persistenceFailed("SYNTHETIC_PRIVATE_DETAIL") })
        }
        let event = try #require(capture.events.first { $0.outcome == .failed })
        #expect(event.operation == "knowledge_entity_identity")
        #expect(event.stage == "merge")
        #expect(event.code == AppError.persistenceFailed("").logCode)
        let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        #expect(!encoded.contains("SYNTHETIC_PRIVATE_DETAIL"))
        #expect(!encoded.contains("Example"))
        let denied = authorization(f, indices: [0])
        await #expect(throws: KnowledgeEntityStoreError.scopeDenied) { try await f.store.mergeEntities(request, authorization: { denied }) }
        #expect(capture.events.filter { $0.outcome == .failed }.count == 1)
    }

    /// Synthetic later compilations with valid, empty ref maps make discovery
    /// forget the old page without deleting any authoritative origin proof.
    private func padDiscovery(_ f: Fixture, oldJobs: Int, extraEntities: Int) throws {
        let context = ModelContext(f.container)
        context.autosaveEnabled = false
        let original = f.requests[0].snapshot
        let source = try #require(original.recordings.first)
        let fingerprint = try #require(source.fingerprint)
        let startingRevision = try KnowledgeStoreRows.latestRevision(in: context)
        for index in 0..<max(1, oldJobs) {
            let version = "padding-\(index)"
            let identity = try KnowledgeCompilationIdentity(scope: "workspace", meetingID: f.meetings[0].id,
                transcriptFingerprint: original.transcriptFingerprint, extractorVersion: version)
            let job = KnowledgeJob(idempotencyKey: try identity.idempotencyKey(), kind: .extraction, meetingID: f.meetings[0].id,
                pipelineVersion: version, createdAt: Date().addingTimeInterval(Double(index + 1)))
            var entityIDs: [String: UUID] = [:]
            if index == 0 {
                for value in 1...max(1, extraEntities) where extraEntities > 0 {
                    // UUID() produces v4 identities; these v0 fixtures sort
                    // before every possible allocated v4 identity.
                    let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value)))
                    context.insert(KnowledgeEntity(id: id, kind: .project, canonicalName: "Example Padding \(value)",
                        normalizedName: "example padding \(value)", aliasesData: try KnowledgeStoreRows.authoritativeData([String]())))
                    entityIDs["e\(value)"] = id
                }
            }
            let pass = KnowledgeCommitProvenance.Pass(entityIDs: entityIDs, assertionIDs: [:], eventIDs: [:], attributionAnchors: [:])
            let provenance = KnowledgeCommitProvenance(recordings: [.init(recordingID: source.id, transcriptFingerprint: fingerprint,
                strategy: "fullContext", targetedPassCount: 0, passes: [pass])])
            job.checkpointData = try KnowledgeStoreRows.authoritativeData(provenance)
            job.coverageData = try KnowledgeStoreRows.authoritativeData([KnowledgeCommitProvenance.Coverage(recordingID: source.id,
                examinedSegmentIDs: source.segments.map { $0.id.uuidString.lowercased() })])
            job.stateRaw = "succeeded"
            context.insert(job)
            context.insert(KnowledgeRevision(number: startingRevision + index + 1, jobID: job.id,
                policyRevisionKey: original.policyRevisionKey, assertionCount: 0))
        }
        try context.save()
    }

    @Test func mutationProofsAndUndoRemainAvailableBeyondBothDiscoveryCaps() async throws {
        for history in [true, false] {
            let f = try await fixture(names: ["Example Original", "Example Target"])
            let ids = try entityIDs(f)
            let access = authorization(f)
            let original = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[0], targetID: ids[1], snapshot: try await snapshot(f))
            let applied = try await f.store.mergeEntities(original, authorization: { access })
            try padDiscovery(f, oldJobs: history ? 129 : 1, extraEntities: history ? 0 : 1_026)
            let discovery = try await snapshot(f)
            #expect(discovery.isTruncated)
            #expect(!discovery.entities.contains { $0.id == ids[0] })
            #expect(try await f.store.mergeEntities(original, authorization: { access }) == applied)
            let writeProof = try await f.store.entityMutationSnapshot(meetingIDs: access.meetingIDs, scope: "workspace", authorization: { access })
            _ = try await f.store.undoEntityMerge(operationID: original.operationID, snapshot: writeProof, authorization: { access })
            let after = ModelContext(f.container)
            #expect(try after.fetch(FetchDescriptor<KnowledgeEntity>()).first { $0.id == ids[0] }?.mergedIntoID == nil)
            let fresh = try await f.store.entityMutationSnapshot(meetingIDs: access.meetingIDs, scope: "workspace", authorization: { access })
            // A fresh explicit decision also proves exact origins by paging,
            // rather than requiring the old entities to be in a candidate page.
            let again = KnowledgeEntityMergeRequest(operationID: UUID(), sourceID: ids[0], targetID: ids[1], snapshot: fresh)
            _ = try await f.store.mergeEntities(again, authorization: { access })
            #expect(try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeEntity>()).first { $0.id == ids[0] }?.mergedIntoID == ids[1])
        }
    }

}
}

/// The log handler is Sendable; capture reads and writes share the same lock.
private final class EntityMutationEventCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ReliabilityEvent] = []
    func record(_ event: ReliabilityEvent) { lock.withLock { values.append(event) } }
    var events: [ReliabilityEvent] { lock.withLock { values } }
}
