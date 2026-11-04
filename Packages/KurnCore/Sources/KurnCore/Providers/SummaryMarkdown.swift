//
//  SummaryMarkdown.swift
//  KurnCore
//
//  The summary contract every cloud vendor is asked for: plain Markdown in
//  which each "## " heading opens a section. The app still stores, renders,
//  exports, translates and reads aloud an ordered `[SummarySection]`; this is
//  where the model's Markdown becomes that list, so nothing downstream had to
//  change when the wire format stopped being JSON.
//
//  Markdown replaced a `{"sections":[…]}` JSON contract. Writing prose inside
//  JSON strings is where models went wrong — double-escaped "\n", fences
//  around the object, prose around the braces — and the JSON mode that
//  suppressed those failures had to be requested per vendor. Markdown is what
//  the models write natively; the section structure survives as headings.
//
//  Rules, all tolerant because this reads a model's output:
//  - A "## " line outside a code fence starts a section; its text is the
//    title. When the reply has no "## " heading but does use "# ", those are
//    the sections instead. Text before the first section heading becomes an
//    untitled section — except a lone "# " document title, which is dropped.
//  - A line made only of "📷" and "[mm:ss]" stamps lists the photos the
//    section drew on (`SummarySection.photoTimestamps`) and is removed from
//    the body. The stamps are the model's copy of the transcript's own
//    "[mm:ss] 📷 Photo:" lines, never arithmetic it had to do.
//  - A reply wrapped in one code fence is unwrapped, and one that is a JSON
//    object in the old shape is still accepted (`SummaryJSON`), so a model
//    that ignores the instruction does not lose the summary.
//

import Foundation

public enum SummaryMarkdown {
    /// The marker that opens a photo-reference line, in the prompt and here.
    public static let photoMarker = "📷"

    /// Parse a summary reply into sections. Throws `AppError.decodingError`
    /// only when the reply holds no content at all.
    public static func sections(from raw: String) throws -> [SummarySection] {
        let text = unwrappingFence(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.hasPrefix("{"), let json = try? SummaryJSON.parse(text) {
            let sections = json.summarySections
            if !sections.isEmpty { return sections }
        }
        let sections = parseMarkdown(text)
        guard !sections.isEmpty else {
            throw AppError.decodingError("summary reply had no content")
        }
        return sections
    }

    // MARK: - Markdown

    private struct Line {
        let text: String
        /// Heading level when this line is an ATX heading outside a fence.
        let headingLevel: Int?
        let headingText: String
    }

    private static func parseMarkdown(_ text: String) -> [SummarySection] {
        let lines = classify(text)
        let levels = Set(lines.compactMap(\.headingLevel))
        let sectionLevel = levels.contains(2) ? 2 : (levels.contains(1) ? 1 : nil)

        var sections: [(title: String?, lines: [String])] = []
        var current: (title: String?, lines: [String]) = (nil, [])
        for line in lines {
            if let level = line.headingLevel, level == sectionLevel {
                sections.append(current)
                current = (line.headingText, [])
            } else if sectionLevel == 2, line.headingLevel == 1, current.title == nil {
                // A document title ("# Meeting summary") above the sections.
                continue
            } else {
                current.lines.append(line.text)
            }
        }
        sections.append(current)

        return sections.compactMap { makeSection(title: $0.title ?? "", lines: $0.lines) }
    }

    private static func classify(_ text: String) -> [Line] {
        var inFence = false
        return text.components(separatedBy: "\n").map { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return Line(text: line, headingLevel: nil, headingText: "")
            }
            guard !inFence, let heading = heading(in: line) else {
                return Line(text: line, headingLevel: nil, headingText: "")
            }
            return Line(text: line, headingLevel: heading.level, headingText: heading.text)
        }
    }

    /// An ATX heading ("## Title", up to three leading spaces, optional
    /// closing hashes), with surrounding bold markers removed from the title.
    static func heading(in line: String) -> (level: Int, text: String)? {
        let leading = line.prefix(while: { $0 == " " })
        guard leading.count <= 3 else { return nil }
        let rest = line.dropFirst(leading.count)
        let hashes = rest.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let afterHashes = rest.dropFirst(hashes.count)
        guard afterHashes.isEmpty || afterHashes.first == " " || afterHashes.first == "\t" else { return nil }
        var title = afterHashes.trimmingCharacters(in: .whitespaces)
        while title.hasSuffix("#") { title.removeLast() }
        title = title.trimmingCharacters(in: .whitespaces)
        for marker in ["**", "__"] where title.count > marker.count * 2
            && title.hasPrefix(marker) && title.hasSuffix(marker) {
            title = String(title.dropFirst(marker.count).dropLast(marker.count))
        }
        return (hashes.count, title.trimmingCharacters(in: .whitespaces))
    }

    private static func makeSection(title: String, lines: [String]) -> SummarySection? {
        var bodyLines: [String] = []
        var photoTimestamps: [TimeInterval] = []
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, let stamps = photoReferences(in: trimmed) {
                photoTimestamps.append(contentsOf: stamps)
            } else {
                bodyLines.append(line)
            }
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else { return nil }
        return SummarySection(title: title, body: body, photoTimestamps: photoTimestamps)
    }

    /// The stamps of a photo-reference line ("📷 [12:34] [1:02:03]", optionally
    /// with one label such as "Photos:" after the marker), or `nil` when the
    /// line is anything else — a sentence that merely starts with the camera
    /// stays in the body.
    static func photoReferences(in line: String) -> [TimeInterval]? {
        // Compared by scalar: "📷" followed by a variation selector is a
        // different `Character`, so `hasPrefix` would miss it.
        guard line.unicodeScalars.first == photoMarker.unicodeScalars.first else { return nil }
        let rest = String(line.unicodeScalars.dropFirst()).replacingOccurrences(of: "\u{FE0F}", with: "")
        var tokens = rest
            .components(separatedBy: CharacterSet(charactersIn: " \t,;"))
            .filter { !$0.isEmpty }
        if let first = tokens.first, first.hasSuffix(":"), SummaryJSON.parseClockDisplay(first) == nil {
            tokens.removeFirst()
        }
        guard !tokens.isEmpty else { return nil }
        let stamps = tokens.compactMap(SummaryJSON.parseClockDisplay)
        return stamps.count == tokens.count ? stamps : nil
    }

    /// Remove a fence that wraps the entire reply ("```markdown … ```").
    private static func unwrappingFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6,
              let firstNewline = text.firstIndex(of: "\n") else { return text }
        let inner = text[text.index(after: firstNewline)...].dropLast(3)
        // Only unwrap when the closing fence is the only other one; a reply
        // that merely starts and ends with separate code blocks is kept.
        guard !inner.contains("```") else { return text }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
