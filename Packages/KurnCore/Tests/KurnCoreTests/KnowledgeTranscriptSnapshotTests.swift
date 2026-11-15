import Foundation
import Testing
@testable import KurnCore

struct KnowledgeTranscriptSnapshotTests {
    private func segment() -> TranscriptSegment {
        TranscriptSegment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                          speakerLabel: "S1", startTime: 1, endTime: 2, text: "Aprovado.")
    }

    @Test func encodingIsStableAndVersioned() throws {
        let snapshot = try KnowledgeTranscriptSnapshot(segments: [segment()], language: "pt")
        let expected = "28:kurn.knowledge-transcript.v12:pt1:136:00000000-0000-0000-0000-000000000001"
            + "2:S119:460718241880001740819:46116860184273879049:Aprovado.3:nil"
        #expect(snapshot.canonicalData == Data(expected.utf8))
        let repeated = try KnowledgeTranscriptSnapshot(segments: [segment()], language: "pt")
        #expect(snapshot.canonicalData == repeated.canonicalData)
    }

    @Test func everySourceFieldAndOrderChangesRevisionBytes() throws {
        let base = segment()
        let reference = try KnowledgeTranscriptSnapshot(segments: [base], language: "pt").canonicalData
        var edits: [TranscriptSegment] = []
        var edit = base
        edit.id = UUID()
        edits.append(edit)
        edit = base
        edit.speakerLabel = "S2"
        edits.append(edit)
        edit = base
        edit.startTime += 0.000001
        edits.append(edit)
        edit = base
        edit.endTime += 0.000001
        edits.append(edit)
        edit = base
        edit.text = "Não aprovado."
        edits.append(edit)
        edit = base
        edit.confidence = 0.9
        edits.append(edit)
        for changed in edits {
            let changedSnapshot = try KnowledgeTranscriptSnapshot(segments: [changed], language: "pt")
            #expect(reference != changedSnapshot.canonicalData)
        }
        let otherLanguage = try KnowledgeTranscriptSnapshot(segments: [base], language: "en")
        #expect(reference != otherLanguage.canonicalData)
        let other = edits[0]
        #expect(try KnowledgeTranscriptSnapshot(segments: [base, other], language: "pt").canonicalData
                != KnowledgeTranscriptSnapshot(segments: [other, base], language: "pt").canonicalData)
    }

    @Test func anchorsRetainOrderAndRoundOutwards() throws {
        var first = segment()
        first.startTime = 1.0001
        first.endTime = 1.0002
        var second = segment()
        second.id = UUID()
        second.startTime = 0
        second.endTime = 3
        let snapshot = try KnowledgeTranscriptSnapshot(segments: [first, second], language: "pt")
        #expect(snapshot.sourceSegments.map(\.id) == [first.id, second.id].map { $0.uuidString.lowercased() })
        #expect(snapshot.sourceSegments[0].startMs == 1_000)
        #expect(snapshot.sourceSegments[0].endMs == 1_001)
        let claim = KnowledgeEvidenceClaim(segmentIDs: [snapshot.sourceSegments[0].id], quote: first.text)
        #expect(try KnowledgeEvidenceValidator(segments: snapshot.sourceSegments).validate(claim).get().normalizedQuote == first.text)
    }

    @Test func malformedSourcesFailClosedWithoutTrapping() {
        let base = segment()
        #expect(throws: KnowledgeTranscriptSnapshotError.duplicateSegmentID) {
            try KnowledgeTranscriptSnapshot(segments: [base, base], language: "pt")
        }
        for start in [-1, Double.nan, .infinity, .greatestFiniteMagnitude, 2] {
            var invalid = base
            invalid.startTime = start
            #expect(throws: KnowledgeTranscriptSnapshotError.invalidTimeRange) {
                try KnowledgeTranscriptSnapshot(segments: [invalid], language: "pt")
            }
        }
        for end in [0, Double.nan, .infinity, .greatestFiniteMagnitude] {
            var invalid = base
            invalid.endTime = end
            #expect(throws: KnowledgeTranscriptSnapshotError.invalidTimeRange) {
                try KnowledgeTranscriptSnapshot(segments: [invalid], language: "pt")
            }
        }
        var invalid = base
        invalid.confidence = .nan
        #expect(throws: KnowledgeTranscriptSnapshotError.invalidConfidence) {
            try KnowledgeTranscriptSnapshot(segments: [invalid], language: "pt")
        }
    }

    @Test func lengthPrefixesDisambiguateTextAndPreserveUnicodeBytes() throws {
        var first = segment()
        first.speakerLabel = "A:B"
        first.text = "C\n🔒"
        var second = first
        second.speakerLabel = "A"
        second.text = "B:C\n🔒"
        #expect(try KnowledgeTranscriptSnapshot(segments: [first], language: "").canonicalData
                != KnowledgeTranscriptSnapshot(segments: [second], language: "").canonicalData)
        first.text = "café"
        second = first
        second.text = "cafe\u{301}"
        #expect(try KnowledgeTranscriptSnapshot(segments: [first], language: "").canonicalData
                != KnowledgeTranscriptSnapshot(segments: [second], language: "").canonicalData)
        #expect(try KnowledgeTranscriptSnapshot(segments: [], language: "").sourceSegments.isEmpty)
    }
}
