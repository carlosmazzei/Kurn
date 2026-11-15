import CryptoKit
import Foundation
import KurnCore
import SwiftData

/// Synchronous helpers called only inside KnowledgeStore's actor. Keeping them
/// outside the actor API prevents passing a live context across that boundary.
enum KnowledgeStoreRows {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func latestRevision(in context: ModelContext) throws -> Int {
        var descriptor = FetchDescriptor<KnowledgeRevision>(sortBy: [SortDescriptor(\KnowledgeRevision.number, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.number ?? 0
    }

    static func readSnapshot(
        meetingID: UUID, scope: String, auth: KnowledgeExtractionAuthorization, in context: ModelContext
    ) throws -> KnowledgeStoreSnapshot {
        let meetings = try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID }))
        guard let meeting = meetings.first else { throw KnowledgeStoreError.sourceMissing }
        let links = try context.fetch(FetchDescriptor<SourceContextLink>(predicate: #Predicate { $0.meetingID == meetingID }))
        guard links.count <= 1 else { throw KnowledgeStoreError.ambiguousContext }
        var occasion: KnowledgeContext?
        if let link = links.first {
            let contextID = link.contextID
            occasion = try context.fetch(FetchDescriptor<KnowledgeContext>(predicate: #Predicate { $0.id == contextID })).first
            guard occasion != nil else { throw KnowledgeStoreError.invalidContext }
        }
        guard let classification = KnowledgeClassification(rawValue: occasion?.classificationRaw ?? KnowledgeClassification.internal.rawValue),
              KnowledgeContextKind(rawValue: occasion?.kindRaw ?? KnowledgeContextKind.unknown.rawValue) != nil else {
            throw KnowledgeStoreError.invalidContext
        }
        var sources: [KnowledgeStoreSnapshot.RecordingSource] = []
        var fields = ["kurn.knowledge-meeting.v1", meeting.id.uuidString, meeting.title,
                      String(meeting.createdAt.timeIntervalSince1970.bitPattern)]
        fields += [occasion?.id.uuidString ?? "", occasion?.kindRaw ?? "unknown", occasion?.name ?? "",
                   String(classification.rawValue), occasion?.policyID ?? "",
                   occasion?.startedAt.map { String($0.timeIntervalSince1970.bitPattern) } ?? ""]
        for recording in meeting.recordings.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let transcript = recording.transcript
            if transcript != nil, !recording.isReadyForConsumption { throw KnowledgeStoreError.sourceNotReady }
            let revision = try transcript?.knowledgeRevision()
            let segments = transcript?.segments ?? []
            sources.append(KnowledgeStoreSnapshot.RecordingSource(id: recording.id, transcriptID: transcript?.id,
                fingerprint: revision?.fingerprint, language: transcript?.language ?? "", segments: segments, recordedAt: recording.recordedAt))
            fields += [recording.id.uuidString, recording.captureStateRaw, String(recording.recordedAt.timeIntervalSince1970.bitPattern),
                       transcript?.id.uuidString ?? "", revision?.fingerprint ?? ""]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return KnowledgeStoreSnapshot(meetingID: meetingID, scope: scope, canonicalRevision: try latestRevision(in: context),
            transcriptFingerprint: digest(try encoder.encode(fields)), policyRevisionKey: KnowledgePolicyEvaluator.revisionKey(auth.policies),
            recordings: sources, contextID: occasion?.id, contextClassification: classification, contextPolicyID: occasion?.policyID)
    }

    static func authorize(_ auth: KnowledgeExtractionAuthorization, source: KnowledgeStoreSnapshot, provider: AIProvider) throws {
        var effective = auth
        effective.sourceClassifications.append(source.contextClassification)
        if let policyID = source.contextPolicyID {
            guard auth.policies.contains(where: { $0.id.uuidString.lowercased() == policyID.lowercased() }) else {
                throw KnowledgeStoreError.policyDenied
            }
        }
        guard effective.decision(for: provider).isAllowed else { throw KnowledgeStoreError.policyDenied }
    }

    struct ValidatedRecording {
        let source: KnowledgeStoreSnapshot.RecordingSource
        let compilation: KnowledgeRecordingCompilation
        let documents: [KnowledgeExtraction]
    }

    static func validate(
        _ compilations: [KnowledgeRecordingCompilation], against snapshot: KnowledgeStoreSnapshot
    ) throws -> [ValidatedRecording] {
        let sources = snapshot.recordings.filter { $0.transcriptID != nil && !$0.segments.isEmpty }
        guard !sources.isEmpty, Set(compilations.map(\.recordingID)).count == compilations.count,
              Set(sources.map(\.id)) == Set(compilations.map(\.recordingID)) else { throw KnowledgeStoreError.invalidCompilation }
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        return try compilations.map { compilation in
            guard let source = byID[compilation.recordingID], source.fingerprint == compilation.transcriptFingerprint,
                  ["fullContext", "blocks"].contains(compilation.strategy), compilation.targetedPassCount >= 0,
                  (1...64).contains(compilation.passes.count) else { throw KnowledgeStoreError.invalidCompilation }
            let revision = try KnowledgeTranscriptRevision(segments: source.segments, language: source.language)
            let documents = try compilation.passes.map { try KnowledgeExtraction.decode($0, segments: revision.snapshot.sourceSegments) }
            let covered = Set(documents.flatMap(\.examinedSegmentIDs))
            guard covered == Set(revision.snapshot.sourceSegments.map(\.id)) else { throw KnowledgeStoreError.incompleteCoverage }
            return ValidatedRecording(source: source, compilation: compilation, documents: documents)
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func retirePrevious(
        identity: KnowledgeCompilationIdentity, current: KnowledgeStoreSnapshot, at now: Date, in context: ModelContext
    ) throws {
        let meetingID = identity.meetingID
        let jobs = try context.fetch(FetchDescriptor<KnowledgeJob>(predicate: #Predicate { $0.meetingID == meetingID }))
        let oldJobIDs = Set(jobs.filter { KnowledgeCompilationIdentity(idempotencyKey: $0.idempotencyKey)?.scope == identity.scope }.map(\.id))
        let revisions = try context.fetch(FetchDescriptor<KnowledgeRevision>())
        let oldRevisionIDs = Set(revisions.filter { $0.jobID.map(oldJobIDs.contains) ?? false }.map(\.id))
        let evidence = try context.fetch(FetchDescriptor<KnowledgeEvidence>(predicate: #Predicate { $0.meetingID == meetingID }))
        let sources = Dictionary(uniqueKeysWithValues: current.recordings.map { ($0.id, $0.fingerprint) })
        for item in evidence {
            if let recordingID = item.recordingID, let fingerprint = sources[recordingID] ?? nil, fingerprint == item.transcriptFingerprint { continue }
            item.isAvailable = false
        }
        let supported = Set(evidence.filter(\.isAvailable).map(\.assertionID))
        let assertions = try context.fetch(FetchDescriptor<KnowledgeAssertion>(predicate: #Predicate { $0.sourceMeetingID == meetingID }))
        for assertion in assertions where assertion.retractedAt == nil {
            let replaced = oldRevisionIDs.contains(assertion.revisionID) && assertion.reviewStateRaw == KnowledgeReviewState.machineExtracted.rawValue
            if replaced || !supported.contains(assertion.id) {
                assertion.retractedAt = now
                assertion.reviewStateRaw = KnowledgeReviewState.invalidated.rawValue
            }
        }
    }
}
