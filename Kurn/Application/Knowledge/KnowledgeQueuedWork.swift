import CryptoKit
import Foundation
import KurnCore

/// Host-authored intent. Source text and intermediate notes stay in the
/// protected store, never preferences or a loose task file.
struct KnowledgeQueuedWork: Codable, Sendable, Equatable {
    let key: String
    let kind: KnowledgeJobKind
    let meetingID: UUID
    let pipelineVersion: String
    let provider: AIProvider
    let model: String
    let sourceFingerprint: String
    let force: Bool
    let explicitlyRequested: Bool

    // swiftlint:disable:next function_parameter_count
    static func article(meetingID: UUID, generator: String, provider: AIProvider, model: String,
                        fingerprint: String, force: Bool, explicit: Bool = false, generation: String = "") throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let providerDigest = SHA256.hash(data: try encoder.encode(provider)).map { String(format: "%02x", $0) }.joined()
        let fields = [meetingID.uuidString.lowercased(), generator, providerDigest, model, fingerprint, explicit ? "explicit" : "automatic", generation]
        let digest = SHA256.hash(data: try encoder.encode(fields)).map { String(format: "%02x", $0) }.joined()
        return Self(key: "knowledge.article.v1:\(digest)\(force ? ":\(UUID().uuidString)" : "")", kind: .meetingArticle,
            meetingID: meetingID, pipelineVersion: generator, provider: provider, model: model,
            sourceFingerprint: fingerprint, force: force, explicitlyRequested: explicit)
    }

    func regenerated() -> Self {
        Self(key: key + ":\(UUID().uuidString)", kind: kind, meetingID: meetingID, pipelineVersion: pipelineVersion,
            provider: provider, model: model, sourceFingerprint: sourceFingerprint, force: force, explicitlyRequested: explicitlyRequested)
    }
}

struct KnowledgeQueueEnvelope: Codable, Sendable {
    var version = 1
    let work: KnowledgeQueuedWork
    var leaseID: UUID?
    var failures = 0
    var hasStarted = false
    var progress: Data?
}

struct KnowledgeJobHandle: Sendable {
    let id: UUID
    let leaseID: UUID
    let work: KnowledgeQueuedWork
    let isExplicit: Bool
}

struct KnowledgeQueuedRecord: Sendable {
    let id: UUID
    let state: KnowledgeJobState
    let code: String?
    let envelope: KnowledgeQueueEnvelope?
}

enum KnowledgeQueueError: String, Error {
    case unreadableCheckpoint = "unreadable_knowledge_checkpoint"
    case unsupportedCheckpoint = "unsupported_knowledge_checkpoint"
    case staleLease = "stale_knowledge_lease"
    case persistenceFailed = "knowledge_queue_persistence_failed"
    case workFailed = "knowledge_work_failed"
}

/// A deferral is not a failure and never consumes the retry allowance.
struct KnowledgeJobDeferred: Error {
    enum Reason: String {
        case featureDisabled = "feature_disabled"
        case providerUnavailable = "provider_unavailable"
        case providerBlocked = "provider_blocked"
        case background, recording
    }
    let reason: Reason
}

enum KnowledgeWorkObsolete: String, Error { case sourceChanged = "source_changed", providerChanged = "provider_changed", sourceDeleted = "source_deleted" }
