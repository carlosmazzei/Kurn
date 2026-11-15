import Foundation
import KurnCore
import Testing
@testable import Kurn

struct KnowledgeTranscriptRevisionTests {
    @Test @MainActor func fingerprintAndEvidenceFollowTheCurrentTranscript() throws {
        let segment = TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            speakerLabel: "S1", startTime: 0, endTime: 1, text: "Approved.")
        let transcript = Transcript(segments: [segment], language: "en")
        let original = try transcript.knowledgeRevision()
        #expect(original.fingerprint.count == 64)
        #expect(original.fingerprint == "3fd88f465f639eeab57129e209cc2a3f9f75719b05b087ca49cfa7290a4f5150")
        let claim = KnowledgeEvidenceClaim(segmentIDs: [segment.id.uuidString.lowercased()], quote: segment.text)
        #expect(original.resolve(claim, transcriptFingerprint: original.fingerprint) != nil)
        transcript.createdAt = .distantPast
        #expect(try transcript.knowledgeRevision().fingerprint == original.fingerprint)
        var corrected = segment
        corrected.text = "Not approved."
        transcript.segments = [corrected]
        let current = try transcript.knowledgeRevision()
        #expect(current.fingerprint != original.fingerprint)
        #expect(current.resolve(claim, transcriptFingerprint: original.fingerprint) == nil)
        // The same quote and segment UUID surviving another edit are still stale.
        corrected.text = segment.text
        corrected.speakerLabel = "S2"
        transcript.segments = [corrected]
        #expect(try transcript.knowledgeRevision().resolve(claim, transcriptFingerprint: original.fingerprint) == nil)
    }

    @Test @MainActor func corruptionCannotMasqueradeAsAnEmptyRevision() throws {
        let transcript = Transcript()
        #expect(try transcript.knowledgeRevision().snapshot.sourceSegments.isEmpty)
        transcript.segmentsData = Data("broken".utf8)
        #expect(throws: KnowledgeTranscriptSnapshotError.unreadableTranscript) { try transcript.knowledgeRevision() }
    }
}
