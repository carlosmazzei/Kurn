//
//  SpokenText.swift
//  KurnCore
//
//  Turns what the app *renders* (Markdown summaries, wiki articles, generated
//  documents) into what a voice should *say*, and cuts it into pieces a speech
//  engine accepts.
//
//  Read aloud verbatim, Markdown is noise: "hash hash Decisions", "asterisk
//  asterisk Ana asterisk asterisk", and — the worst offender in this app —
//  every `[12:34]` citation the summary and wiki prompts ask for, spoken as
//  "twelve thirty-four" after each sentence. So the text is rebuilt from
//  `MarkdownBlockParser`'s blocks rather than scrubbed with one regex: headings
//  and list items become their own sentences (a trailing period is what makes
//  every engine pause there), tables read row by row, rules and fences vanish.
//
//  Chunking exists because every cloud engine caps one request (OpenAI 4096
//  characters, Groq 200) and because shorter pieces start playing sooner. The
//  split prefers paragraph, then sentence, then word boundaries, and only cuts
//  inside a word when a single word is longer than the limit — never producing
//  an empty chunk and never dropping text.
//

import Foundation

public enum SpokenText {

    // MARK: - Markdown → speech

    /// Spoken form of a Markdown document: one paragraph per block, separated
    /// by blank lines so `chunks(_:maxCharacters:)` prefers those boundaries.
    public static func fromMarkdown(_ markdown: String) -> String {
        paragraphs(from: MarkdownBlockParser.parse(markdown))
            .joined(separator: "\n\n")
    }

    /// Spoken form of a template-driven summary: each section's title, body and
    /// items in the order `SummaryView` draws them.
    public static func fromSections(_ sections: [SummarySection]) -> String {
        var parts: [String] = []
        for section in sections {
            let title = sentence(inline(section.title))
            if !title.isEmpty { parts.append(title) }
            let body = fromMarkdown(section.body)
            if !body.isEmpty { parts.append(body) }
            for item in section.items {
                // Items may carry their own sub-bullets on extra lines or a
                // leading task box; both go through the block parser too.
                let spoken = fromMarkdown(listNormalized(item))
                if !spoken.isEmpty { parts.append(spoken) }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func paragraphs(from blocks: [MarkdownBlock]) -> [String] {
        var result: [String] = []
        for block in blocks {
            switch block {
            case .heading(_, let text), .paragraph(let text):
                append(sentence(inline(text)), to: &result)
            case .list(let items):
                let lines = items.map { sentence(inline($0.text)) }.filter { !$0.isEmpty }
                append(lines.joined(separator: "\n"), to: &result)
            case .blockquote(let inner):
                result.append(contentsOf: paragraphs(from: inner))
            case .codeBlock:
                // Code read symbol by symbol helps nobody; the surrounding
                // prose already says what it is for.
                continue
            case .table(let headers, let rows):
                append(tableSentences(headers: headers, rows: rows), to: &result)
            case .horizontalRule:
                continue
            }
        }
        return result
    }

    private static func append(_ text: String, to result: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
    }

    /// "Owner: Ana, Deadline: Friday." per row — headers name the cells, which
    /// is what a listener cannot see.
    private static func tableSentences(headers: [String], rows: [[String]]) -> String {
        let cleanHeaders = headers.map(inline)
        return rows.map { row in
            let cells = row.enumerated().compactMap { index, cell -> String? in
                let value = inline(cell)
                guard !value.isEmpty else { return nil }
                let header = index < cleanHeaders.count ? cleanHeaders[index] : ""
                return header.isEmpty ? value : "\(header): \(value)"
            }
            return sentence(cells.joined(separator: ", "))
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    /// A summary item is a single bullet's text; prefix a marker when it has
    /// none so the parser reads the first line as a list item, not a heading
    /// or a stray `[ ]`.
    private static func listNormalized(_ item: String) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "-*+".contains(first) { return trimmed }
        return "- \(trimmed)"
    }

    // MARK: - Inline cleanup

    /// Patterns, not compiled expressions: `NSRegularExpression` is not
    /// `Sendable` on every Foundation this package builds against, and these
    /// run once per paragraph, not per character.
    private static let inlineRules: [(pattern: String, template: String)] = [
        // Timestamps and ranges: [12:34], [1:02:03], [12:34–13:10], (12:34).
        (#"\s*[\[(]\d{1,2}:\d{2}(?::\d{2})?(?:\s*[-–—]\s*\d{1,2}:\d{2}(?::\d{2})?)?[\])]"#, ""),
        // Images and links keep only their visible text.
        (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"),
        // Emphasis, strong and strikethrough keep their content. The single
        // `_` form requires a non-word boundary so snake_case survives.
        (#"\*\*(.+?)\*\*"#, "$1"),
        (#"__(.+?)__"#, "$1"),
        (#"~~(.+?)~~"#, "$1"),
        (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "$1"),
        (#"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, "$1"),
        (#"`([^`]*)`"#, "$1"),
        // Bare URLs are unpronounceable; the sentence around them survives.
        (#"https?://\S+"#, ""),
        // Leftover HTML the models occasionally emit (<br>, <u>…</u>).
        (#"<[^>]+>"#, " ")
    ]

    /// Strip inline Markdown and citations from one line of text, collapsing
    /// the whitespace the removals leave behind.
    public static func inline(_ text: String) -> String {
        var result = text
        for rule in inlineRules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let template = rule.template
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        let collapsed = result
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // A removed trailing citation can leave "decided ." behind.
        return collapsed
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
            .trimmingCharacters(in: .whitespaces)
    }

    /// End with terminal punctuation so a speech engine pauses between a
    /// heading or bullet and whatever follows it.
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        if ".!?…:;。！？".contains(last) { return trimmed }
        return trimmed + "."
    }

    // MARK: - Chunking

    /// Split `text` into pieces of at most `maxCharacters` characters, cutting
    /// at the coarsest boundary that fits: paragraph, then sentence, then word.
    /// The concatenation of the chunks carries every word of the input.
    public static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        let limit = max(1, maxCharacters)
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result: [String] = []
        var current = ""
        for piece in paragraphs.flatMap({ pieces(of: $0, limit: limit) }) {
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= limit {
                current += "\n" + piece
            } else {
                result.append(current)
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// One paragraph as units no longer than `limit`: itself when it fits,
    /// otherwise its sentences (packed), otherwise its words (packed).
    private static func pieces(of paragraph: String, limit: Int) -> [String] {
        guard paragraph.count > limit else { return [paragraph] }
        let units = sentences(in: paragraph).flatMap { sentence -> [String] in
            guard sentence.count > limit else { return [sentence] }
            return words(in: sentence, limit: limit)
        }
        return pack(units, limit: limit)
    }

    /// Sentences split at line breaks and after terminal punctuation followed
    /// by whitespace (or, for CJK full-width marks, immediately). Deliberately not
    /// `enumerateSubstrings(options: .bySentences)`: that is unavailable in
    /// Linux Foundation, where this package is tested.
    private static func sentences(in paragraph: String) -> [String] {
        let terminals: Set<Character> = [".", "!", "?", "…"]
        let fullWidthTerminals: Set<Character> = ["。", "！", "？"]
        var sentences: [String] = []
        var current = ""
        var pendingBreak = false
        for character in paragraph {
            if character.isNewline || (pendingBreak && character.isWhitespace) {
                sentences.append(current)
                current = ""
                pendingBreak = false
                continue
            }
            pendingBreak = false
            current.append(character)
            if fullWidthTerminals.contains(character) {
                sentences.append(current)
                current = ""
            } else if terminals.contains(character) {
                pendingBreak = true
            }
        }
        sentences.append(current)
        let trimmed = sentences
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return trimmed.isEmpty ? [paragraph] : trimmed
    }

    /// Words of an over-long sentence; a single word longer than `limit`
    /// (a pasted hash, an unsegmented script) is hard-cut into pieces.
    private static func words(in sentence: String, limit: Int) -> [String] {
        let words = sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let units = words.flatMap { word -> [String] in
            guard word.count > limit else { return [word] }
            var pieces: [String] = []
            var rest = Substring(word)
            while !rest.isEmpty {
                pieces.append(String(rest.prefix(limit)))
                rest = rest.dropFirst(limit)
            }
            return pieces
        }
        return pack(units, limit: limit)
    }

    private static func pack(_ units: [String], limit: Int) -> [String] {
        var packed: [String] = []
        var current = ""
        for unit in units {
            if current.isEmpty {
                current = unit
            } else if current.count + 1 + unit.count <= limit {
                current += " " + unit
            } else {
                packed.append(current)
                current = unit
            }
        }
        if !current.isEmpty { packed.append(current) }
        return packed
    }
}
