import Foundation

public struct FluidAudioStartTimedWord: Sendable, Hashable {
    public var text: String
    public var start: TimeInterval

    public init(text: String, start: TimeInterval) {
        self.text = text
        self.start = start
    }
}

public enum FluidAudioWordTiming {
    public static let maxEstimatedWordDuration: TimeInterval = 1.5

    public static func spans(
        from words: [FluidAudioStartTimedWord],
        duration: TimeInterval
    ) throws -> [TranscribedSpan] {
        let transcript = RawTranscript(spans: words.map {
            TranscribedSpan(text: $0.text, start: $0.start, end: $0.start)
        }, language: "")
        let normalized = try ChunkTimestampNormalization.normalize(transcript, duration: duration).spans
        return normalized.enumerated().map { index, word in
            let estimatedEnd = min(duration, word.start + maxEstimatedWordDuration)
            let end: TimeInterval
            if index + 1 == normalized.count {
                end = estimatedEnd
            } else {
                let nextStart = normalized[index + 1].start
                end = nextStart >= word.start ? min(nextStart, estimatedEnd) : min(duration, word.start + 0.04)
            }
            return TranscribedSpan(text: word.text, start: word.start, end: end)
        }
    }
}
