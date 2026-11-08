import Foundation

/// Compact line-oriented text for source-tool results. The model reads results as plain text, so
/// per-item JSON keys, quoting and repeated meeting IDs only spent tokens (about 45% of a
/// transcript page). Times use the transcript's own `[m:ss]` form the prompt asks the model to cite.
/// Every result ends with one `page:` line, the only pagination contract the model needs.
enum ChatSourceToolText {
    static let truncationMarker = " [truncated]"

    /// One field on one line: newlines collapsed, clipped to `limit` Unicode scalars.
    static func field(_ text: String, limit: Int = 500) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.unicodeScalars.count > limit else { return flat }
        return String(String.UnicodeScalarView(flat.unicodeScalars.prefix(limit))) + truncationMarker
    }

    /// `[m:ss]`, or `[h:mm:ss]` past an hour: the exact form the app's transcript, summaries and
    /// retrieval prompts render (`TimeInterval.clockDisplay`, rounded), so a citation copied from a
    /// tool result matches the moment the user sees.
    static func timestamp(_ seconds: Double) -> String {
        "[\(duration(seconds))]"
    }

    /// Mirrors `TimeInterval.clockDisplay` in the app target, which KurnCore cannot import.
    static func duration(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds, rule: .toNearestOrAwayFromZero)
        let hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60
        return hours > 0 ? "\(hours):\(twoDigits(minutes)):\(twoDigits(rest))" : "\(minutes):\(twoDigits(rest))"
    }

    private static func wholeSeconds(_ seconds: Double, rule: FloatingPointRoundingRule) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 1_000_000_000).rounded(rule))
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    static func date(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// `page: items 1–10 of 25; next offset: 10` or `…; end`. `unit` names what is counted.
    static func pageLine(offset: Int, count: Int, total: Int, unit: String = "items") -> String {
        let next = offset + count
        let range = count == 0 ? "no \(unit)" : "\(unit) \(offset + 1)–\(next)"
        let tail = next < total && count > 0 ? "next offset: \(next)" : "end"
        return "page: \(range) of \(total); \(tail)"
    }

    static func source(_ source: ChatSource, readable: [ChatSourcePart]) -> String {
        var line = "- \(source.id.uuidString) | \(field(source.title)) | \(date(source.date))"
            + " | \(duration(source.duration))"
        if let folder = source.folder { line += " | folder: \(field(folder))" }
        if !source.tags.isEmpty {
            line += " | tags: " + source.tags.prefix(10).map { field($0, limit: 100) }.joined(separator: ", ")
            if source.tags.count > 10 { line += " (+\(source.tags.count - 10) more)" }
        }
        let parts = readable.map(\.rawValue)
        return line + " | readable: " + (parts.isEmpty ? "none" : parts.joined(separator: ", "))
    }

    /// Passages grouped under a `meeting <id>` header each time the meeting changes, keeping the
    /// given (ranked) order, so an ID is written once per run of passages instead of per passage.
    static func passages(_ passages: [ChatSourcePassage]) -> [String] {
        var lines: [String] = []
        var current: UUID?
        for passage in passages {
            if passage.meetingID != current {
                lines.append("meeting \(passage.meetingID.uuidString):")
                current = passage.meetingID
            }
            lines.append("\(timestamp(passage.timestamp)) \(field(passage.speaker, limit: 100)): \(field(passage.text))")
        }
        return lines
    }
}
