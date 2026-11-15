import Foundation
import KurnCore

/// No live SwiftData model crosses the writer's actor boundary.
struct KnowledgeStoreSnapshot: Sendable {
    let meetingID: UUID
    let scope: String
    let canonicalRevision: Int
    let transcriptFingerprint: String
    let policyRevisionKey: String
    let recordings: [RecordingSource]
    let contextID: UUID?
    let contextClassification: KnowledgeClassification
    let contextPolicyID: String?
    var contextKind: KnowledgeContextKind = .unknown

    struct RecordingSource: Sendable {
        let id: UUID
        let transcriptID: UUID?
        let fingerprint: String?
        let language: String
        let segments: [TranscriptSegment]
        let recordedAt: Date
    }
}

struct KnowledgeRecordingCompilation: Codable, Sendable {
    let recordingID: UUID
    let transcriptFingerprint: String
    let strategy: String
    let targetedPassCount: Int
    /// Encoded contract documents, revalidated against the store's source at
    /// commit. A caller cannot smuggle a manually constructed Codable value in.
    let passes: [Data]

    init(recordingID: UUID, result: KnowledgeExtractionService.Result) throws {
        self.recordingID = recordingID
        self.transcriptFingerprint = result.transcriptFingerprint
        self.strategy = result.strategy.rawValue
        self.targetedPassCount = result.targetedPassCount
        self.passes = try result.passes.map { try JSONEncoder().encode($0) }
    }
}

struct KnowledgeCommitRequest: Sendable {
    let snapshot: KnowledgeStoreSnapshot
    let extractorVersion: String
    let schemaVersion: Int
    let provider: AIProvider
    let compilations: [KnowledgeRecordingCompilation]
    var generation: String? = nil
    var lease: KnowledgeJobHandle? = nil
}

struct KnowledgeCommitReceipt: Sendable, Equatable {
    let revisionID: UUID
    let number: Int
    let jobID: UUID?
    let assertionCount: Int
    let projectionPending: Bool
    let isReplay: Bool
}

enum KnowledgeStoreError: String, Error, Sendable {
    case policyDenied = "knowledge_policy_denied"
    case policyChanged = "knowledge_policy_changed"
    case sourceMissing = "knowledge_source_missing"
    case sourceChanged = "knowledge_source_changed"
    case sourceNotReady = "knowledge_source_not_ready"
    case ambiguousContext = "knowledge_ambiguous_context"
    case invalidContext = "knowledge_invalid_context"
    case staleRevision = "knowledge_stale_revision"
    case invalidCompilation = "knowledge_invalid_compilation"
    case incompleteCoverage = "knowledge_incomplete_coverage"
    case obsoleteJob = "knowledge_obsolete_job"
    case corruptedProvenance = "knowledge_corrupted_provenance"
    case unsupportedProvenanceVersion = "knowledge_unsupported_provenance_version"
    case invalidJob = "knowledge_invalid_job"
    case cancelledJob = "knowledge_cancelled_job"
}

/// Retained on the succeeded job, in the protected store. K1.6 may use the
/// checkpoint while running, but must retain this provenance once committed:
/// the V7 canonical rows have no dedicated attribution/ref-map fields.
struct KnowledgeCommitProvenance: Codable {
    var recordings: [Recording]
    var resolutionSummary: KnowledgeEntityResolutionSummary?
    struct Recording: Codable {
        let recordingID: UUID
        let transcriptFingerprint: String
        let strategy: String
        let targetedPassCount: Int
        var passes: [Pass]
    }
    struct Pass: Codable {
        let entityIDs: [String: UUID]
        let assertionIDs: [String: UUID]
        let eventIDs: [String: UUID]
        /// Canonical assertion ID -> original attribution segment anchor.
        let attributionAnchors: [String: String]
    }
    struct Coverage: Codable {
        let recordingID: UUID
        let examinedSegmentIDs: [String]
    }
}
