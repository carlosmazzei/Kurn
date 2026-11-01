import Foundation
import Testing
import KurnCore

struct TranscriptIntegrityDiagnosticTests {
    private func segment(
        start: TimeInterval = 0,
        end: TimeInterval = 5,
        text: String = "private transcript content",
        speaker: String = "private speaker name"
    ) -> TranscriptSegment {
        TranscriptSegment(speakerLabel: speaker, startTime: start, endTime: end, text: text)
    }

    private func expectDiagnostic(
        segments: [TranscriptSegment],
        sourceDuration: TimeInterval = 20,
        failure: TranscriptIntegrityFailure,
        detail: TranscriptIntegrityDetail,
        segmentIndex: Int?
    ) throws {
        let diagnostic = try #require(TranscriptIntegrityGate.diagnose(
            segments: segments,
            sourceDuration: sourceDuration,
            hadTranscribedInput: true
        ))
        #expect(diagnostic.failure == failure)
        #expect(diagnostic.detail == detail)
        #expect(diagnostic.segmentIndex == segmentIndex)
        #expect(TranscriptIntegrityGate.validate(
            segments: segments,
            sourceDuration: sourceDuration,
            hadTranscribedInput: true
        ) == diagnostic.failure)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteSourceHasNoSegmentIndex(sourceDuration: Double) throws {
        try expectDiagnostic(
            segments: [segment()],
            sourceDuration: sourceDuration,
            failure: .sourceUnreadable,
            detail: .sourceDurationNonFinite,
            segmentIndex: nil
        )
    }

    @Test(arguments: [-1.0, -Double.leastNonzeroMagnitude])
    func negativeSourceHasNoSegmentIndex(sourceDuration: Double) throws {
        try expectDiagnostic(
            segments: [segment()],
            sourceDuration: sourceDuration,
            failure: .sourceUnreadable,
            detail: .sourceDurationNegative,
            segmentIndex: nil
        )
    }

    @Test func missingOutputHasNoSegmentIndex() throws {
        try expectDiagnostic(
            segments: [],
            failure: .emptyOutputFromNonEmptyInput,
            detail: .emptyOutputFromNonEmptyInput,
            segmentIndex: nil
        )
    }

    @Test(arguments: [true, false])
    func sourceFailurePrecedesEmptyOutput(hadInput: Bool) throws {
        let diagnostic = try #require(TranscriptIntegrityGate.diagnose(
            segments: [],
            sourceDuration: .nan,
            hadTranscribedInput: hadInput
        ))
        #expect(diagnostic.failure == .sourceUnreadable)
        #expect(diagnostic.detail == .sourceDurationNonFinite)
        #expect(diagnostic.segmentIndex == nil)
        #expect(TranscriptIntegrityGate.validate(
            segments: [],
            sourceDuration: .nan,
            hadTranscribedInput: hadInput
        ) == diagnostic.failure)
    }

    @Test(arguments: [
        (Double.nan, 8.0, TranscriptIntegrityDetail.nonFiniteStartTime),
        (Double.infinity, 8.0, .nonFiniteStartTime),
        (-Double.infinity, 8.0, .nonFiniteStartTime),
        (6.0, Double.nan, .nonFiniteEndTime),
        (6.0, Double.infinity, .nonFiniteEndTime),
        (6.0, -Double.infinity, .nonFiniteEndTime),
        (-1.0, 8.0, .negativeStartTime),
        (6.0, -1.0, .negativeEndTime),
        (8.0, 6.0, .invertedTimeRange),
        (51.0, 55.0, .startBeyondSourceDuration),
        (6.0, 51.0, .endBeyondSourceDuration)
    ])
    func invalidBoundsIdentifyTheFieldAndZeroBasedIndex(
        start: Double,
        end: Double,
        detail: TranscriptIntegrityDetail
    ) throws {
        try expectDiagnostic(
            segments: [segment(), segment(start: start, end: end)],
            failure: .segmentOutOfBounds,
            detail: detail,
            segmentIndex: 1
        )
    }

    @Test func nonFiniteBoundsPrecedeNegativeAndInvertedBounds() throws {
        try expectDiagnostic(
            segments: [segment(start: -1, end: .nan)],
            failure: .segmentOutOfBounds,
            detail: .nonFiniteEndTime,
            segmentIndex: 0
        )
    }

    @Test func firstOffendingSegmentWins() throws {
        try expectDiagnostic(
            segments: [segment(text: ""), segment(start: .nan)],
            failure: .emptySegmentText,
            detail: .emptyText,
            segmentIndex: 0
        )
    }

    @Test func orderingUsesTheLargestPriorStart() throws {
        try expectDiagnostic(
            segments: [
                segment(start: 100, end: 105),
                segment(start: 75, end: 80),
                segment(start: 45, end: 50)
            ],
            sourceDuration: 200,
            failure: .segmentsOutOfOrder,
            detail: .startOutOfOrder,
            segmentIndex: 2
        )
    }

    @Test func boundsFailurePrecedesOrderingAndContentFailures() throws {
        try expectDiagnostic(
            segments: [segment(start: 100, end: 105), segment(start: 0, end: 300, text: "", speaker: "")],
            sourceDuration: 200,
            failure: .segmentOutOfBounds,
            detail: .endBeyondSourceDuration,
            segmentIndex: 1
        )
    }

    @Test func orderingFailurePrecedesContentFailures() throws {
        try expectDiagnostic(
            segments: [segment(start: 100, end: 105), segment(text: "", speaker: "")],
            sourceDuration: 200,
            failure: .segmentsOutOfOrder,
            detail: .startOutOfOrder,
            segmentIndex: 1
        )
    }

    @Test(arguments: ["", " \t\r\n "])
    func blankTextIdentifiesItsSegment(text: String) throws {
        try expectDiagnostic(
            segments: [segment(), segment(start: 6, end: 8, text: text, speaker: "")],
            failure: .emptySegmentText,
            detail: .emptyText,
            segmentIndex: 1
        )
    }

    @Test(arguments: ["", " \t\r\n "])
    func blankSpeakerIdentifiesItsSegment(speaker: String) throws {
        try expectDiagnostic(
            segments: [segment(), segment(start: 6, end: 8, speaker: speaker)],
            failure: .unattributedSpeaker,
            detail: .emptySpeaker,
            segmentIndex: 1
        )
    }

    @Test func acceptedOutputsHaveNoDiagnostic() {
        let cases: [(segments: [TranscriptSegment], duration: Double)] = [
            ([], 20),
            ([], 0),
            ([segment(start: 0, end: 0)], 0),
            ([segment(start: -0.0, end: 0)], -0.0),
            ([segment(start: 0, end: 30)], 0),
            ([segment(start: 50, end: 50)], 20),
            ([segment(start: 100, end: 105), segment(start: 70, end: 80)], 200),
            ([segment()], Double.greatestFiniteMagnitude)
        ]
        #expect(TranscriptIntegrityGate.boundsSlack == 30)
        for testCase in cases {
            #expect(TranscriptIntegrityGate.diagnose(
                segments: testCase.segments,
                sourceDuration: testCase.duration,
                hadTranscribedInput: !testCase.segments.isEmpty
            ) == nil)
            #expect(TranscriptIntegrityGate.validate(
                segments: testCase.segments,
                sourceDuration: testCase.duration,
                hadTranscribedInput: !testCase.segments.isEmpty
            ) == nil)
        }
    }

    @Test func boundsSlackIsNotWidened() throws {
        try expectDiagnostic(
            segments: [segment(end: Double(50).nextUp)],
            failure: .segmentOutOfBounds,
            detail: .endBeyondSourceDuration,
            segmentIndex: 0
        )
    }

    @Test func orderingSlackIsNotWidened() throws {
        try expectDiagnostic(
            segments: [segment(start: 100, end: 105), segment(start: Double(70).nextDown, end: 80)],
            sourceDuration: 200,
            failure: .segmentsOutOfOrder,
            detail: .startOutOfOrder,
            segmentIndex: 1
        )
    }

    @Test func longRecordingOverrunRetainsTheUmbrellaFailure() throws {
        let duration: TimeInterval = 95 * 60
        try expectDiagnostic(
            segments: [segment(), segment(start: duration - 5, end: duration + 31)],
            sourceDuration: duration,
            failure: .segmentOutOfBounds,
            detail: .endBeyondSourceDuration,
            segmentIndex: 1
        )
    }

    @Test func diagnosticEncodingContainsOnlyClosedVocabularyAndIndex() throws {
        let diagnostic = try #require(TranscriptIntegrityGate.diagnose(
            segments: [segment(start: 6, end: 4)],
            sourceDuration: 20,
            hadTranscribedInput: true
        ))
        let data = try JSONEncoder().encode(diagnostic)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["failure", "detail", "segmentIndex"])
        #expect(object["failure"] as? String == "segmentOutOfBounds")
        #expect(object["detail"] as? String == "invertedTimeRange")
        #expect(object["segmentIndex"] as? Int == 0)
        #expect(try JSONDecoder().decode(TranscriptIntegrityDiagnostic.self, from: data) == diagnostic)
    }

    @Test func existingFailureRawValuesAndCodableAreUnchanged() throws {
        let expected = [
            "sourceUnreadable",
            "emptyOutputFromNonEmptyInput",
            "segmentOutOfBounds",
            "segmentsOutOfOrder",
            "emptySegmentText",
            "unattributedSpeaker",
            "correctionIdentityViolation"
        ]
        #expect(TranscriptIntegrityFailure.allCases.map(\.rawValue) == expected)
        for failure in TranscriptIntegrityFailure.allCases {
            let data = try JSONEncoder().encode(failure)
            #expect(String(data: data, encoding: .utf8) == "\"\(failure.rawValue)\"")
            #expect(try JSONDecoder().decode(TranscriptIntegrityFailure.self, from: data) == failure)
        }
    }
}
