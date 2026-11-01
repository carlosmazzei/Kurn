import Foundation

public struct NemotronDiarizationTimeline: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case invalidProbabilityShape
    }

    private var frameOffset = 0
    private var activeStarts = [Int?](repeating: nil, count: NemotronDiarizationPolicy.speakerSlots)
    private var segments: [DiarizerSegment] = []

    public init() {}

    public mutating func append(probabilities: [Float], frameCount: Int) throws {
        let (expectedCount, countOverflow) = frameCount.multipliedReportingOverflow(
            by: NemotronDiarizationPolicy.speakerSlots
        )
        let (nextOffset, offsetOverflow) = frameOffset.addingReportingOverflow(frameCount)
        guard frameCount >= 0, !countOverflow, !offsetOverflow, probabilities.count == expectedCount else {
            throw Failure.invalidProbabilityShape
        }
        for frame in 0..<frameCount {
            for slot in activeStarts.indices {
                let probability = probabilities[frame * NemotronDiarizationPolicy.speakerSlots + slot]
                let active = probability.isFinite
                    && probability >= NemotronDiarizationPolicy.activityThreshold && probability <= 1
                let position = frameOffset + frame
                if active {
                    if activeStarts[slot] == nil { activeStarts[slot] = position }
                } else if let start = activeStarts[slot] {
                    segments.append(Self.segment(slot: slot, startFrame: start, endFrame: position))
                    activeStarts[slot] = nil
                }
            }
        }
        frameOffset = nextOffset
    }

    public func turns(sourceDuration: TimeInterval) -> [SpeakerTurn] {
        guard sourceDuration.isFinite, sourceDuration > 0 else { return [] }
        var completed = segments
        for (slot, start) in activeStarts.enumerated() {
            if let start {
                completed.append(Self.segment(slot: slot, startFrame: start, endFrame: frameOffset))
            }
        }
        let clamped = completed.compactMap { segment -> DiarizerSegment? in
            let end = min(segment.end, sourceDuration)
            guard end > segment.start,
                  end - segment.start + 1e-9 >= NemotronDiarizationPolicy.minimumSpeechDuration else { return nil }
            return DiarizerSegment(speakerID: segment.speakerID, start: segment.start, end: end)
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.speakerID != $1.speakerID { return $0.speakerID < $1.speakerID }
            return $0.end < $1.end
        }
        return DiarizerSegmentLabeling.turns(from: clamped)
    }

    public static func turns(
        probabilities: [Float],
        frameCount: Int,
        sourceDuration: TimeInterval
    ) throws -> [SpeakerTurn] {
        var timeline = Self()
        try timeline.append(probabilities: probabilities, frameCount: frameCount)
        return timeline.turns(sourceDuration: sourceDuration)
    }

    private static func segment(slot: Int, startFrame: Int, endFrame: Int) -> DiarizerSegment {
        DiarizerSegment(
            speakerID: String(slot),
            start: Double(startFrame) * NemotronDiarizationPolicy.frameSeconds,
            end: Double(endFrame) * NemotronDiarizationPolicy.frameSeconds
        )
    }
}
