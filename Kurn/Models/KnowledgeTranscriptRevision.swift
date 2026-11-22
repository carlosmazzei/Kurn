import CryptoKit
import Foundation
import KurnCore

/// Immutable source revision for extraction and evidence resolution. Construct
/// again at commit (K1.5); a changed fingerprint makes an in-flight result stale.
struct KnowledgeTranscriptRevision: Sendable {
    let fingerprint: String
    let snapshot: KnowledgeTranscriptSnapshot

    init(segments: [TranscriptSegment], language: String) throws {
        let snapshot = try KnowledgeTranscriptSnapshot(segments: segments, language: language)
        self.snapshot = snapshot
        self.fingerprint = SHA256.hash(data: snapshot.canonicalData)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// No retained transcript history: old anchors must not resolve against a
    /// new revision, even if its UUIDs and quote happen to survive an edit.
    func resolve(_ claim: KnowledgeEvidenceClaim, transcriptFingerprint: String) -> KnowledgeValidatedEvidence? {
        guard transcriptFingerprint == fingerprint else { return nil }
        return try? KnowledgeEvidenceValidator(segments: snapshot.sourceSegments).validate(claim).get()
    }
}

extension Transcript {
    /// Decode authoritative bytes directly: corruption must never fingerprint
    /// as the empty transcript returned by the presentation convenience getter.
    func knowledgeRevision() throws -> KnowledgeTranscriptRevision {
        guard let segments = JSONStorage.decodeAuthoritative([TranscriptSegment].self, from: segmentsData).decodedValue else {
            throw KnowledgeTranscriptSnapshotError.unreadableTranscript
        }
        return try KnowledgeTranscriptRevision(segments: segments, language: language)
    }
}
