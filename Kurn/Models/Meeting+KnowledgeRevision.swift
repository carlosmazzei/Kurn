//
//  Meeting+KnowledgeRevision.swift
//  Kurn
//
//  The meeting's transcript as the Knowledge Engine cites it (K1.3, CLAUDE.md
//  "Knowledge Engine decisions"): KurnCore's `KnowledgeTranscriptRevision`
//  built over every transcribed recording in chronological order, with each
//  recording's offset on the meeting timeline, and its fingerprint — the
//  SHA-256 of the revision's canonical encoding, which evidence records so a
//  citation is only ever checked against the transcript it was taken from.
//

import CryptoKit
import Foundation
import KurnCore

extension Meeting {
    /// The meeting's current transcript revision; empty when nothing is
    /// transcribed. Offsets count every recording, as `startOffset(of:)` does,
    /// so an untranscribed gap does not move later segments.
    func knowledgeTranscriptRevision() -> KnowledgeTranscriptRevision {
        let sources = recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .compactMap { recording -> KnowledgeTranscriptSource? in
                guard let segments = recording.transcript?.segments, !segments.isEmpty else { return nil }
                return KnowledgeTranscriptSource(recordingID: recording.id, offset: startOffset(of: recording), segments: segments)
            }
        return KnowledgeTranscriptRevision(sources: sources)
    }
}

extension KnowledgeTranscriptRevision {
    /// Lowercase hex SHA-256 of `canonicalEncoding`: what
    /// `KnowledgeEvidence.transcriptFingerprint` stores.
    var fingerprint: String {
        SHA256.hash(data: canonicalEncoding).map { String(format: "%02x", $0) }.joined()
    }
}
