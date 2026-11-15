import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct KnowledgeMaintenanceTests {
    private struct Fixture {
        let container: ModelContainer
        let context: ModelContext
        let meetings: [Meeting]
        let store: KnowledgeStore
        var auth: KnowledgeSourceAuthorization
        var ids: Set<UUID> { Set(meetings.map(\.id)) }
    }

    private func fixture(count: Int = 1) throws -> Fixture {
        let schema = KurnModelGraph.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let meetings = (0..<count).map { index in
            let meeting = Meeting(title: "Synthetic maintenance \(index)")
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
            auth: KnowledgeSourceAuthorization(featureEnabled: true, meetingIDs: Set(meetings.map(\.id)),
                policies: [KnowledgeProcessingPolicy()], sourceClassifications: [.internal]))
    }

    // swiftlint:disable:next function_parameter_count
    private func compile(_ f: Fixture, meetingID: UUID? = nil, scope: String = "workspace", version: String = "synthetic-v1",
                         unused: Bool = false, duplicate: Bool = false) async throws {
        let auth = f.auth.extraction
        let token = try await f.store.snapshot(meetingID: meetingID ?? f.meetings[0].id, scope: scope,
            provider: .appleOnDevice, authorization: { auth })
        let source = try #require(token.recordings.first)
        let segment = try #require(source.segments.first)
        let anchor = segment.id.uuidString.lowercased()
        var entities: [[String: Any]] = [["ref": "e1", "kind": "project", "name": "Example portal", "aliases": []],
            ["ref": "e2", "kind": "project", "name": duplicate ? "Example portal" : "Example service", "aliases": []]]
        if unused { entities.append(["ref": "e3", "kind": "topic", "name": "Unused example", "aliases": []]) }
        let wire: [String: Any] = ["version": 1, "entities": entities,
            "assertions": [["ref": "a1", "subject": "e1", "predicate": "dependsOn", "object": "e2",
                "modality": "reported", "polarity": "positive", "claimKind": "internalStatusReport", "authorityStatus": "attributed",
                "confidence": "medium", "attributedToSegmentID": anchor,
                "evidence": [["segmentIDs": [anchor], "quote": segment.text]]]], "events": [], "examinedSegmentIDs": [anchor]]
        let document = try JSONDecoder().decode(KnowledgeExtraction.self, from: JSONSerialization.data(withJSONObject: wire))
        let result = KnowledgeExtractionService.Result(transcriptFingerprint: try #require(source.fingerprint), strategy: .fullContext,
            passes: [document], examinedSegmentIDs: [anchor], targetedPassCount: 0)
        _ = try await f.store.commit(KnowledgeCommitRequest(snapshot: token, extractorVersion: version, schemaVersion: 1, provider: .appleOnDevice,
            compilations: [try KnowledgeRecordingCompilation(recordingID: source.id, result: result)]), authorization: { auth })
    }

    private func report(_ f: Fixture, ids: Set<UUID>? = nil) async throws -> KnowledgeScopedMaintenanceReport {
        let auth = f.auth
        return try await f.store.maintenanceReport(meetingIDs: ids ?? f.ids, scope: "workspace", authorization: { auth })
    }

    private func project(_ f: Fixture) async throws {
        let auth = f.auth
        let snapshot = try await f.store.wikiProjectionSnapshot(meetingIDs: f.ids, scope: "workspace", authorization: { auth })
        _ = try await f.store.publishWikiProjection(snapshot, authorization: { auth })
    }

    private func job(_ kind: KnowledgeJobKind, in context: ModelContext) throws -> KnowledgeJob {
        let raw = kind.rawValue
        return try #require(context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.kindRaw == raw })).first)
    }

    private func codes(_ report: KnowledgeScopedMaintenanceReport) -> Set<KnowledgeMaintenanceFinding.Code> { Set(report.report.findings.map(\.code)) }

    @Test func cleanInspectionIsReadOnlyDeterministicAndSurvivesWriterRecreation() async throws {
        let f = try fixture()
        #expect(try await codes(report(f)) == [.compilationMissing])
        try await compile(f)
        #expect(try await codes(report(f)) == [.projectionMissing])
        try await project(f)
        let context = ModelContext(f.container)
        let projection = try job(.projection, in: context).checkpointData
        let provenance = try job(.extraction, in: context).checkpointData
        let first = try await report(f)
        #expect(first.report.isClean)
        #expect(first.report.coverage.first?.examinedSegments == 1)
        #expect(try await report(f) == first)
        let reopened = KnowledgeStore(modelContainer: f.container)
        let auth = f.auth
        #expect(try await reopened.maintenanceReport(meetingIDs: f.ids, scope: "workspace", authorization: { auth }) == first)
        #expect(try JSONDecoder().decode(KnowledgeScopedMaintenanceReport.self, from: JSONEncoder().encode(first)) == first)
        #expect(try job(.projection, in: ModelContext(f.container)).checkpointData == projection)
        #expect(try job(.extraction, in: ModelContext(f.container)).checkpointData == provenance)
        #expect(try await f.store.pendingProjection() == nil)
        #expect(try ModelContext(f.container).fetchCount(FetchDescriptor<KnowledgeJob>()) == 2)
        let text = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(!text.contains("Example portal"))
        #expect(!text.contains("Speaker 1"))
    }

    @Test func onlyCurrentUnusedEntitiesAreOrphansAndHistoryIsPreserved() async throws {
        let f = try fixture()
        try await compile(f, unused: true)
        try await project(f)
        let first = try await report(f)
        #expect(codes(first) == [.orphanEntity])
        let orphan = try #require(first.report.findings.first?.subjects.first?.id)
        try await compile(f, version: "synthetic-v2")
        try await project(f)
        #expect(try await report(f).report.isClean)
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeEntity>()).contains { $0.id == orphan })
    }

    @Test func partialUnknownAndCorruptCoverageNeverImplyCompleteExamination() async throws {
        let f = try fixture()
        try await compile(f)
        try await project(f)
        let context = ModelContext(f.container)
        let row = try job(.extraction, in: context)
        let recordingID = try #require(f.meetings[0].recordings.first?.id)
        row.coverageData = try KnowledgeStoreRows.authoritativeData([KnowledgeCommitProvenance.Coverage(recordingID: recordingID, examinedSegmentIDs: [])])
        try context.save()
        #expect(try await codes(report(f)) == [.coverageGap])
        row.coverageData = try KnowledgeStoreRows.authoritativeData([KnowledgeCommitProvenance.Coverage(recordingID: recordingID, examinedSegmentIDs: ["unknown-anchor"])])
        try context.save()
        let unknown = try await report(f)
        #expect(!unknown.report.isComplete)
        #expect(unknown.report.coverage.first?.examinedSegments == 0)
        #expect(codes(unknown).contains(.artifactUnreadable))
        row.coverageData = Data("broken bytes".utf8)
        try context.save()
        #expect(try await !report(f).report.isClean)
        #expect(try job(.extraction, in: ModelContext(f.container)).coverageData == row.coverageData)
    }

    @Test func sourceAndPolicyChangesHideOldDetailsAndReportTheCoverageReason() async throws {
        var f = try fixture()
        try await compile(f)
        try await project(f)
        f.auth.policies[0].revision += 1
        #expect(try await codes(report(f)) == [.policyChanged, .staleProjection])
        f.auth.policies[0].revision -= 1
        let transcript = try #require(f.meetings[0].recordings.first?.transcript)
        var segments = transcript.segments
        segments[0].text += " Updated."
        transcript.segments = segments
        try f.context.save()
        let stale = try await report(f)
        #expect(codes(stale) == [.sourceChanged, .staleProjection])
        #expect(stale.report.findings.allSatisfy { $0.subjects.allSatisfy { $0.kind == .recording } })
    }

    @Test func liveACLFeatureAndLintPermissionAreIndependentOfPageNarrativePermission() async throws {
        var f = try fixture()
        try await compile(f)
        try await project(f)
        f.auth.policies[0].allowedOperations.remove(.pageNarrative)
        #expect(try await report(f).report.isClean)
        for index in 0..<3 {
            var denied = f
            if index == 0 { denied.auth.featureEnabled = false }
            if index == 1 { denied.auth.meetingIDs = [] }
            if index == 2 { denied.auth.policies[0].allowedOperations.remove(.semanticLint) }
            await #expect(throws: KnowledgeWikiStoreError.scopeDenied) { try await report(denied) }
        }
        let context = KnowledgeContext(kind: .internalMeeting, name: "Synthetic restricted", policyID: UUID().uuidString)
        f.context.insert(context)
        f.context.insert(SourceContextLink(meetingID: f.meetings[0].id, contextID: context.id))
        try f.context.save()
        await #expect(throws: KnowledgeWikiStoreError.scopeDenied) { try await report(f) }
    }

    @Test func unselectedMeetingsAndOtherScopesDoNotContributeFindingsOrCounts() async throws {
        let f = try fixture(count: 2)
        try await compile(f, meetingID: f.meetings[0].id)
        try await compile(f, meetingID: f.meetings[1].id, unused: true)
        try await compile(f, meetingID: f.meetings[0].id, scope: "other", version: "other-v1", unused: true)
        f.context.insert(KnowledgeReview(kind: .mergeCandidate, subjectIDsData: try KnowledgeStoreRows.authoritativeData([UUID(), UUID()]),
            payloadData: Data(#"{"version":999}"#.utf8)))
        try f.context.save()
        let selected = try await report(f, ids: [f.meetings[0].id])
        #expect(codes(selected) == [.projectionMissing])
        #expect(selected.report.coverage.count == 1)
        let text = String(decoding: try JSONEncoder().encode(selected), as: UTF8.self).lowercased()
        #expect(!text.contains(f.meetings[1].id.uuidString.lowercased()))
        #expect(!text.contains(try #require(f.meetings[1].recordings.first?.id).uuidString.lowercased()))
    }

    @Test func identityCandidatesAreDeduplicatedWithoutResolvingReviews() async throws {
        let f = try fixture()
        try await compile(f, duplicate: true)
        try await project(f)
        let context = ModelContext(f.container)
        let row = try #require(context.fetch(FetchDescriptor<KnowledgeReview>()).first)
        context.insert(KnowledgeReview(kind: .mergeCandidate, subjectIDsData: row.subjectIDsData, payloadData: row.payloadData))
        try context.save()
        let result = try await report(f)
        #expect(codes(result) == [.duplicateCandidate])
        #expect(result.report.findings.count == 1)
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeReview>()).allSatisfy { $0.stateRaw == "open" })
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeEntity>()).allSatisfy { $0.mergedIntoID == nil })
    }

    @Test func futureArtifactsAreRefusedAndOriginalBytesArePreserved() async throws {
        for kind in [KnowledgeJobKind.extraction, .projection] {
            let f = try fixture()
            try await compile(f)
            try await project(f)
            let context = ModelContext(f.container)
            let row = try job(kind, in: context)
            var envelope = try #require(JSONSerialization.jsonObject(with: try #require(row.checkpointData)) as? [String: Any])
            envelope["version"] = 999
            let future = try JSONSerialization.data(withJSONObject: envelope)
            row.checkpointData = future
            try context.save()
            await #expect(throws: KnowledgeMaintenanceError.unsupportedArtifact) { try await report(f) }
            #expect(try job(kind, in: ModelContext(f.container)).checkpointData == future)
        }
    }

    @Test func invalidCanonicalEvidenceProducesAnIncompleteReportWithoutLeakingContent() async throws {
        let f = try fixture()
        try await compile(f)
        try await project(f)
        let context = ModelContext(f.container)
        let evidence = try #require(context.fetch(FetchDescriptor<KnowledgeEvidence>()).first)
        evidence.quote = "Synthetic invalid evidence text."
        try context.save()
        let result = try await report(f)
        #expect(!result.report.isComplete)
        #expect(codes(result).contains(.canonicalUnavailable))
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains(evidence.quote))
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeEvidence>()).first?.quote == evidence.quote)
    }

    @Test func futureSelectedReviewIsRefusedWithoutChangingItsStateOrBytes() async throws {
        let f = try fixture()
        try await compile(f, duplicate: true)
        let context = ModelContext(f.container)
        let row = try #require(context.fetch(FetchDescriptor<KnowledgeReview>()).first)
        var envelope = try #require(JSONSerialization.jsonObject(with: try #require(row.payloadData)) as? [String: Any])
        envelope["version"] = 999
        let bytes = try JSONSerialization.data(withJSONObject: envelope)
        row.payloadData = bytes
        try context.save()
        await #expect(throws: KnowledgeMaintenanceError.unsupportedArtifact) { try await report(f) }
        let unchanged = try #require(ModelContext(f.container).fetch(FetchDescriptor<KnowledgeReview>()).first)
        #expect(unchanged.payloadData == bytes)
        #expect(unchanged.stateRaw == "open")
    }

    @Test func narrativeOnTheWrongPageCannotBeReportedCleanEvenWithSharedAssertions() async throws {
        let f = try fixture()
        try await compile(f)
        try await project(f)
        let context = ModelContext(f.container)
        let row = try job(.projection, in: context)
        let stored = try KnowledgeWikiProjectionRows.payload(row)
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        var pages = try #require(raw["pages"] as? [[String: Any]])
        pages[0]["narrative"] = ["version": 1, "entityID": stored.pages[1].entity.id.uuidString,
            "paragraphs": [["text": "Synthetic shared claim.", "assertionIDs": [try #require(stored.snapshot.facts.first?.id).uuidString]]]]
        raw["pages"] = pages
        let broken = try JSONDecoder().decode(KnowledgeWikiProjection.self, from: JSONSerialization.data(withJSONObject: raw))
        row.checkpointData = try KnowledgeStoreRows.authoritativeData(broken)
        try context.save()
        #expect(try await codes(report(f)) == [.invalidNarrative])
        let auth = f.auth
        await #expect(throws: KnowledgeWikiStoreError.unreadableProjection) {
            try await f.store.wikiProjection(meetingIDs: f.ids, scope: "workspace", authorization: { auth })
        }
        // The same misplaced narrative with a future schema must be refused
        // before interpreting its page binding as ordinary corruption.
        pages[0]["narrative"] = ["version": 2, "entityID": stored.pages[1].entity.id.uuidString,
            "paragraphs": [["text": "Synthetic future claim.", "assertionIDs": [try #require(stored.snapshot.facts.first?.id).uuidString]]]]
        raw["pages"] = pages
        let future = try JSONDecoder().decode(KnowledgeWikiProjection.self, from: JSONSerialization.data(withJSONObject: raw))
        let bytes = try KnowledgeStoreRows.authoritativeData(future)
        row.checkpointData = bytes
        try context.save()
        await #expect(throws: KnowledgeMaintenanceError.unsupportedArtifact) { try await report(f) }
        #expect(try job(.projection, in: ModelContext(f.container)).checkpointData == bytes)
    }

    @Test func mergedCandidateWithoutReviewIDIsOmittedAndReturnsAfterUndo() async throws {
        let f = try fixture()
        try await compile(f, duplicate: true)
        let context = ModelContext(f.container)
        let review = try #require(context.fetch(FetchDescriptor<KnowledgeReview>()).first)
        let candidate = try #require(KnowledgeEntityResolutionRows.reviewPayload(review).candidate)
        let auth = KnowledgeEntityResolutionAuthorization(extraction: f.auth.extraction, meetingIDs: f.ids)
        let token = try await f.store.entityMutationSnapshot(meetingIDs: f.ids, scope: "workspace", authorization: { auth })
        let operation = UUID()
        _ = try await f.store.mergeEntities(.init(operationID: operation, sourceID: candidate.sourceID,
            targetID: candidate.match.entityID, snapshot: token), authorization: { auth })
        try await project(f)
        #expect(try await report(f).report.isClean)
        let reviewID = review.id
        #expect(try ModelContext(f.container).fetch(FetchDescriptor<KnowledgeReview>(predicate: #Predicate { $0.id == reviewID })).first?.stateRaw == "open")
        let undo = try await f.store.entityMutationSnapshot(meetingIDs: f.ids, scope: "workspace", authorization: { auth })
        _ = try await f.store.undoEntityMerge(operationID: operation, snapshot: undo, authorization: { auth })
        try await project(f)
        #expect(try await codes(report(f)) == [.duplicateCandidate])
    }

    @Test func missingOrMalformedCurrentOrphanYieldsAnIncompleteReportWithOtherCoverage() async throws {
        for variant in 0..<3 {
            let f = try fixture(count: 2)
            try await compile(f, meetingID: f.meetings[0].id, unused: true)
            try await compile(f, meetingID: f.meetings[1].id)
            try await project(f)
            let context = ModelContext(f.container)
            let orphan = try #require(context.fetch(FetchDescriptor<KnowledgeEntity>()).first { $0.canonicalName == "Unused example" })
            if variant == 0 { context.delete(orphan) }
            if variant == 1 { orphan.kindRaw = "invalid-kind" }
            if variant == 2 { orphan.reviewStateRaw = "invalid-state" }
            try context.save()
            let result = try await report(f)
            #expect(!result.report.isComplete)
            #expect(result.report.coverage.count == 2)
            #expect(codes(result).contains(.canonicalUnavailable))
            #expect(!codes(result).contains(.orphanEntity))
            #expect(!codes(result).contains(.duplicateCandidate))
        }
    }

    @Test func wellFormedBrokenProjectionLinksIdentifyOnlyTheReadablePage() async throws {
        let f = try fixture()
        try await compile(f)
        try await project(f)
        let context = ModelContext(f.container)
        let row = try job(.projection, in: context)
        let stored = try KnowledgeWikiProjectionRows.payload(row)
        var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as? [String: Any])
        var pages = try #require(raw["pages"] as? [[String: Any]])
        var sections = try #require(pages[0]["sections"] as? [[String: Any]])
        var entries = try #require(sections[0]["entries"] as? [[String: Any]])
        var subject = try #require(entries[0]["subject"] as? [String: Any])
        let hidden = UUID()
        subject["id"] = hidden.uuidString
        entries[0]["subject"] = subject
        var fact = try #require(entries[0]["fact"] as? [String: Any])
        var source = try #require(fact["source"] as? [String: Any])
        var evidence = try #require(source["evidence"] as? [[String: Any]])
        evidence[0]["id"] = hidden.uuidString
        source["evidence"] = evidence; fact["source"] = source; entries[0]["fact"] = fact
        sections[0]["entries"] = entries; pages[0]["sections"] = sections
        pages[0]["narrative"] = ["version": 1, "entityID": stored.pages[0].entity.id.uuidString,
            "paragraphs": [["text": "Synthetic foreign claim.", "assertionIDs": [hidden.uuidString]]]]
        raw["pages"] = pages
        let broken = try JSONDecoder().decode(KnowledgeWikiProjection.self, from: JSONSerialization.data(withJSONObject: raw))
        let bytes = try KnowledgeStoreRows.authoritativeData(broken)
        row.checkpointData = bytes
        try context.save()
        let result = try await report(f)
        #expect(codes(result).isSuperset(of: [.brokenEntityLink, .brokenEvidenceLink, .invalidProjection, .invalidNarrative]))
        #expect(!String(decoding: try JSONEncoder().encode(result), as: UTF8.self).lowercased().contains(hidden.uuidString.lowercased()))
        #expect(try job(.projection, in: ModelContext(f.container)).checkpointData == bytes)
    }
}
}
