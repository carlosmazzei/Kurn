//
//  MarkdownBlockParser.swift
//  Kurn
//
//  Tolerant block-level Markdown parser for AI summary content. Produces a
//  flat list of blocks (headings, lists with task checkboxes and nesting,
//  blockquotes, fenced code, tables, rules, paragraphs) that the SwiftUI
//  renderer in `MarkdownText` draws. It never fails: anything it does not
//  recognize falls back to a paragraph, since LLM output is only loosely
//  well-formed. Pure value logic with no UI imports so it stays unit-testable.
//

import Foundation

enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case list(items: [MarkdownListItem])
    case blockquote(blocks: [MarkdownBlock])
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case horizontalRule
}

// Kept top-level (not nested in MarkdownListItem) to stay within the
// SwiftLint nesting limit.
enum MarkdownListMarker: Equatable, Sendable {
    case bullet
    case ordered(number: Int)
    case task(checked: Bool)
}

struct MarkdownListItem: Equatable, Sendable {
    /// 0-based nesting depth derived from leading whitespace, clamped so a
    /// runaway indent cannot push content off-screen.
    var indent: Int
    var marker: MarkdownListMarker
    var text: String
}

enum MarkdownBlockParser {
    /// Blockquotes nested beyond this stop recursing and render as plain text.
    private static let maxQuoteDepth = 4
    private static let maxIndentLevel = 6

    static func parse(_ raw: String) -> [MarkdownBlock] {
        parse(lines: raw.components(separatedBy: "\n"), depth: 0)
    }

    /// Detect a task checkbox in a standalone summary item ("[ ] call Bob",
    /// "- [x] send notes"). Items are single strings outside the block parser,
    /// so this is the seam `SummaryView` uses for its bullet rows.
    static func taskItem(in text: String) -> (checked: Bool, text: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "-*+".contains(first) {
            return checkbox(in: trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        return checkbox(in: trimmed)
    }

    // MARK: - Block grouping

    private static func parse(lines: [String], depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
            } else if trimmed.hasPrefix("```") {
                let (block, next) = consumeCodeBlock(lines, from: index)
                blocks.append(block)
                index = next
            } else if let (block, next) = consumeTable(lines, from: index) {
                blocks.append(block)
                index = next
            } else if trimmed.hasPrefix(">") {
                let (block, next) = consumeBlockquote(lines, from: index, depth: depth)
                blocks.append(block)
                index = next
            } else if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule)
                index += 1
            } else if listItem(from: line) != nil {
                let (block, next) = consumeList(lines, from: index)
                blocks.append(block)
                index = next
            } else if let heading = heading(from: trimmed) {
                blocks.append(heading)
                index += 1
            } else {
                blocks.append(.paragraph(text: trimmed))
                index += 1
            }
        }
        return blocks
    }

    /// Collect everything between a ``` fence and its closer (or end of input,
    /// so an unterminated fence still renders as code instead of noise).
    private static func consumeCodeBlock(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        let opener = lines[start].trimmingCharacters(in: .whitespaces)
        let languageText = opener.drop(while: { $0 == "`" }).trimmingCharacters(in: .whitespaces)
        var body: [String] = []
        var index = start + 1
        while index < lines.count,
              !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            body.append(lines[index])
            index += 1
        }
        if index < lines.count { index += 1 }
        let block = MarkdownBlock.codeBlock(
            language: languageText.isEmpty ? nil : languageText,
            code: body.joined(separator: "\n")
        )
        return (block, index)
    }

    /// A table needs a header row and a `|---|` separator on the next line;
    /// without the separator the pipes fall through to a plain paragraph.
    private static func consumeTable(_ lines: [String], from start: Int) -> (MarkdownBlock, Int)? {
        guard let headers = tableCells(lines[start]), !headers.isEmpty,
              start + 1 < lines.count, isTableSeparator(lines[start + 1]) else { return nil }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, let cells = tableCells(lines[index]) {
            rows.append(normalized(cells, width: headers.count))
            index += 1
        }
        return (.table(headers: headers, rows: rows), index)
    }

    private static func consumeBlockquote(
        _ lines: [String],
        from start: Int,
        depth: Int
    ) -> (MarkdownBlock, Int) {
        var inner: [String] = []
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var content = String(trimmed.dropFirst())
            if content.hasPrefix(" ") { content.removeFirst() }
            inner.append(content)
            index += 1
        }
        guard depth < maxQuoteDepth else {
            return (.blockquote(blocks: [.paragraph(text: inner.joined(separator: " "))]), index)
        }
        return (.blockquote(blocks: parse(lines: inner, depth: depth + 1)), index)
    }

    private static func consumeList(_ lines: [String], from start: Int) -> (MarkdownBlock, Int) {
        var items: [MarkdownListItem] = []
        var index = start
        while index < lines.count,
              !isHorizontalRule(lines[index].trimmingCharacters(in: .whitespaces)),
              let item = listItem(from: lines[index]) {
            items.append(item)
            index += 1
        }
        return (.list(items: items), index)
    }

    // MARK: - Line classification

    private static func heading(from trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(from line: String) -> MarkdownListItem? {
        let indent = indentLevel(of: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if "-*+".contains(first) {
            let rest = trimmed.dropFirst()
            guard rest.first == " " else { return nil }
            let text = rest.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            if let task = checkbox(in: text) {
                return MarkdownListItem(indent: indent, marker: .task(checked: task.checked), text: task.text)
            }
            return MarkdownListItem(indent: indent, marker: .bullet, text: text)
        }
        if let ordered = orderedItem(trimmed) {
            return MarkdownListItem(indent: indent, marker: .ordered(number: ordered.number), text: ordered.text)
        }
        return nil
    }

    private static func orderedItem(_ trimmed: String) -> (number: Int, text: String)? {
        guard let separator = trimmed.firstRange(of: ". ") else { return nil }
        let prefix = trimmed[..<separator.lowerBound]
        guard let number = Int(prefix), number > 0 else { return nil }
        let body = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return (number, body)
    }

    private static func checkbox(in text: some StringProtocol) -> (checked: Bool, text: String)? {
        let lowered = text.lowercased()
        let checked: Bool
        if lowered.hasPrefix("[ ]") {
            checked = false
        } else if lowered.hasPrefix("[x]") {
            checked = true
        } else {
            return nil
        }
        return (checked, String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces))
    }

    /// Nesting level from leading whitespace: a tab counts as 4 columns and
    /// every 2 columns is one level, so 2- and 4-space conventions both nest.
    private static func indentLevel(of line: String) -> Int {
        var columns = 0
        for char in line {
            if char == " " {
                columns += 1
            } else if char == "\t" {
                columns += 4
            } else {
                break
            }
        }
        return min(columns / 2, maxIndentLevel)
    }

    // MARK: - Table helpers

    private static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var cells = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed.hasPrefix("|") { cells.removeFirst() }
        if trimmed.hasSuffix("|"), cells.count > 1 { cells.removeLast() }
        return cells
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableCells(line), !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { "-:".contains($0) }
        }
    }

    private static func normalized(_ cells: [String], width: Int) -> [String] {
        if cells.count >= width { return Array(cells.prefix(width)) }
        return cells + Array(repeating: "", count: width - cells.count)
    }
}
