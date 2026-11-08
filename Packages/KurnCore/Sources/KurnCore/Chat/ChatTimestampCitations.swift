import Foundation

/// Timestamps a chat reply cites as `[m:ss]`/`[mm:ss]` or `[h:mm:ss]` — the form the source tools
/// and the transcript render — so the reply's citations can be shown as tappable chips that seek
/// the meeting.
public enum ChatTimestampCitations {
    /// Distinct absolute seconds cited in `text`, in order of first appearance.
    public static func times(in text: String) -> [TimeInterval] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?::(\d{2}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var result: [TimeInterval] = []
        var seen = Set<Int>()
        for match in regex.matches(in: text, range: range) {
            func group(_ index: Int) -> Int? {
                guard let bounds = Range(match.range(at: index), in: text) else { return nil }
                return Int(text[bounds])
            }
            guard let first = group(1), let second = group(2) else { continue }
            let seconds = group(3).map { first * 3_600 + second * 60 + $0 } ?? first * 60 + second
            if seen.insert(seconds).inserted { result.append(TimeInterval(seconds)) }
        }
        return result
    }
}
