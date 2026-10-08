//
//  InlineMarkdown.swift
//  KurnCore
//
//  Resolves one line of inline Markdown — emphasis, strong, strikethrough,
//  code spans, links — into styled runs for the export renderers that cannot
//  show Markdown syntax (plain text, HTML, Word, PDF).
//
//  Like `MarkdownBlockParser`, it never fails: an unmatched delimiter is just
//  text. Links keep only their visible text, never the URL, for the same
//  reason `MarkdownPresentation` disables them on screen: everything parsed
//  here was written by an LLM from a transcript, and a speaker can steer the
//  model into a link that carries meeting content to a server.
//

import Foundation

public struct InlineStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = InlineStyle(rawValue: 1 << 0)
    public static let italic = InlineStyle(rawValue: 1 << 1)
    public static let code = InlineStyle(rawValue: 1 << 2)
    public static let strikethrough = InlineStyle(rawValue: 1 << 3)
}

public struct InlineRun: Equatable, Sendable {
    public var text: String
    public var style: InlineStyle

    public init(_ text: String, style: InlineStyle = []) {
        self.text = text
        self.style = style
    }
}

extension Array where Element == InlineRun {
    /// The runs' text with all styling dropped.
    public var plainText: String { map(\.text).joined() }
}

public enum InlineMarkdown {
    /// Nesting beyond this treats further delimiters as text, so a hostile
    /// run of asterisks cannot recurse without bound.
    private static let maxDepth = 8

    public static func runs(_ text: String) -> [InlineRun] {
        var output: [InlineRun] = []
        parse(Array(text), style: [], depth: 0, into: &output)
        return merged(output)
    }

    // MARK: - Parsing

    private static func parse(_ chars: [Character], style: InlineStyle, depth: Int, into output: inout [InlineRun]) {
        var buffer = ""
        func flush() {
            if !buffer.isEmpty {
                output.append(InlineRun(buffer, style: style))
                buffer = ""
            }
        }

        var index = 0
        while index < chars.count {
            let char = chars[index]

            // Backslash escapes a punctuation character.
            if char == "\\", index + 1 < chars.count, chars[index + 1].isPunctuation || chars[index + 1].isSymbol {
                buffer.append(chars[index + 1])
                index += 2
                continue
            }

            if char == "`", let close = firstIndex(of: "`", in: chars, from: index + 1), close > index + 1 {
                flush()
                output.append(InlineRun(String(chars[(index + 1)..<close]), style: style.union(.code)))
                index = close + 1
                continue
            }

            if depth < maxDepth, let link = link(in: chars, at: index) {
                flush()
                parse(link.label, style: style, depth: depth + 1, into: &output)
                index = link.end
                continue
            }

            if depth < maxDepth, let span = delimitedSpan(in: chars, at: index) {
                flush()
                parse(span.inner, style: style.union(span.style), depth: depth + 1, into: &output)
                index = span.end
                continue
            }

            buffer.append(char)
            index += 1
        }
        flush()
    }

    /// `[label](url)` or `![alt](url)`: the visible text and the index just
    /// past the closing parenthesis.
    private static func link(in chars: [Character], at index: Int) -> (label: [Character], end: Int)? {
        var open = index
        if chars[index] == "!" {
            open += 1
        }
        guard open < chars.count, chars[open] == "[",
              let closeBracket = firstIndex(of: "]", in: chars, from: open + 1),
              closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
              let closeParen = firstIndex(of: ")", in: chars, from: closeBracket + 2)
        else { return nil }
        return (Array(chars[(open + 1)..<closeBracket]), closeParen + 1)
    }

    private struct Span {
        let inner: [Character]
        let style: InlineStyle
        let end: Int
    }

    /// Double delimiters first, so `**bold**` is never read as two empty
    /// italics.
    private static let doubleDelimiters: [(delimiter: Character, style: InlineStyle)] = [
        ("*", .bold), ("_", .bold), ("~", .strikethrough)
    ]

    private static func delimitedSpan(in chars: [Character], at index: Int) -> Span? {
        let char = chars[index]
        for entry in doubleDelimiters where char == entry.delimiter {
            guard index + 1 < chars.count, chars[index + 1] == char else { continue }
            if let span = doubleSpan(in: chars, at: index, delimiter: char, style: entry.style) {
                return span
            }
        }
        guard char == "*" || char == "_" else { return nil }
        return singleSpan(in: chars, at: index, delimiter: char)
    }

    private static func doubleSpan(in chars: [Character], at index: Int, delimiter: Character, style: InlineStyle) -> Span? {
        let start = index + 2
        guard start < chars.count, !chars[start].isWhitespace else { return nil }
        var search = start
        while search + 1 < chars.count {
            if chars[search] == delimiter, chars[search + 1] == delimiter, !chars[search - 1].isWhitespace, search > start {
                return Span(inner: Array(chars[start..<search]), style: style, end: search + 2)
            }
            search += 1
        }
        return nil
    }

    /// `*text*` or `_text_`. The underscore form needs a non-word character on
    /// both outer sides, so `snake_case_name` stays text.
    private static func singleSpan(in chars: [Character], at index: Int, delimiter: Character) -> Span? {
        let start = index + 1
        guard start < chars.count, !chars[start].isWhitespace, chars[start] != delimiter else { return nil }
        if delimiter == "_", index > 0, isWordCharacter(chars[index - 1]) { return nil }
        var search = start + 1
        while search < chars.count {
            if chars[search] == delimiter, !chars[search - 1].isWhitespace {
                let next = search + 1 < chars.count ? chars[search + 1] : nil
                let closesHere = delimiter == "*"
                    ? next != "*"
                    : next.map { !isWordCharacter($0) } ?? true
                if closesHere {
                    return Span(inner: Array(chars[start..<search]), style: .italic, end: search + 1)
                }
            }
            search += 1
        }
        return nil
    }

    private static func isWordCharacter(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_"
    }

    private static func firstIndex(of target: Character, in chars: [Character], from start: Int) -> Int? {
        guard start < chars.count else { return nil }
        return chars[start...].firstIndex(of: target)
    }

    /// Adjacent runs with the same style collapse into one, so renderers emit
    /// one element per visual span rather than one per parse step.
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.style == run.style {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }
}
