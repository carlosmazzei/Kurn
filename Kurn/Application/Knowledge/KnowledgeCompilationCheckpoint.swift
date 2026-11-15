import Foundation
import KurnCore

struct KnowledgeCompilationWork: Codable, Sendable, Equatable {
    static let extractorVersion = "knowledge-extractor-v1"
    let scope: String
    let policyRevisionKey: String
    let timeZone: String
}

/// Completed recording passes only. An interrupted recording is repeated;
/// validated earlier recordings are retained in the protected job checkpoint.
struct KnowledgeCompilationCheckpoint: Codable, Sendable {
    var version = 1
    let workKey: String
    var recordings: [KnowledgeRecordingCompilation] = []

    static func restore(_ data: Data?, work: KnowledgeQueuedWork, snapshot: KnowledgeStoreSnapshot) throws -> Self {
        guard let data else { return Self(workKey: work.key) }
        let decoded = JSONStorage.decodeAuthoritative(Self.self, from: data)
        if case .unsupportedVersion = decoded { throw KnowledgeQueueError.unsupportedCheckpoint }
        guard let value = decoded.decodedValue else { throw KnowledgeQueueError.unreadableCheckpoint }
        guard value.version == 1 else { throw KnowledgeQueueError.unsupportedCheckpoint }
        guard value.workKey == work.key, Set(value.recordings.map(\.recordingID)).count == value.recordings.count else {
            throw KnowledgeQueueError.unreadableCheckpoint
        }
        for recording in value.recordings {
            guard let source = snapshot.recordings.first(where: { $0.id == recording.recordingID }) else { throw KnowledgeStoreError.sourceChanged }
            _ = try KnowledgeStoreRows.validateRecording(recording, source: source)
        }
        return value
    }
}
