//
//  PlainTextExportRenderer.swift
//  KurnCore
//
//  Plain UTF-8 text for an `ExportDocument`: no Markdown syntax, so it pastes
//  cleanly into an email, a ticket or a chat, and opens anywhere. Structure is
//  carried by layout alone — underlined headings, indented bullets.
//

import Foundation

public enum PlainTextExportRenderer {
    public static func render(_ document: ExportDocument) -> String {
        var out = underlined(document.title, with: "=")
        out += "\(document.dateLine)\n"
        if let duration = document.duration {
            out += "\(ExportDocument.durationLabel): \(duration)\n"
        }
        out += "\n"
        var previousWasListItem = false
        for block in document.richBlocks {
            let isListItem: Bool
            if case .listItem = block { isListItem = true } else { isListItem = false }
            // List items are single-spaced; the list as a whole is a block.
            if previousWasListItem, !isListItem { out += "\n" }
            out += render(block)
            previousWasListItem = isListItem
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func render(_ block: ExportRichBlock) -> String {
        switch block {
        case .heading(let level, let runs):
            return underlined(runs.plainText, with: level <= 2 ? "-" : nil)
        case .paragraph(let runs):
            return "\(runs.plainText)\n\n"
        case .listItem(let indent, let marker, let runs):
            let padding = String(repeating: "  ", count: indent)
            return "\(padding)\(listMarker(marker)) \(runs.plainText)\n"
        case .quote(let runs):
            let lines = runs.plainText.components(separatedBy: "\n").map { "> \($0)" }
            return lines.joined(separator: "\n") + "\n\n"
        case .code(let code):
            let lines = code.components(separatedBy: "\n").map { "    \($0)" }
            return lines.joined(separator: "\n") + "\n\n"
        case .table(let headers, let rows):
            var lines = [headers.map(\.plainText).joined(separator: " | ")]
            lines += rows.map { $0.map(\.plainText).joined(separator: " | ") }
            return lines.joined(separator: "\n") + "\n\n"
        case .rule:
            return String(repeating: "—", count: 12) + "\n\n"
        }
    }

    /// The glyph each list marker reads as, shared with the other rich
    /// renderers so a task box looks the same in every format.
    public static func listMarker(_ marker: MarkdownListMarker) -> String {
        switch marker {
        case .bullet: return "•"
        case .ordered(let number): return "\(number)."
        case .task(let checked): return checked ? "☑" : "☐"
        }
    }

    /// Text followed by a rule of `character` as wide as the text, or the text
    /// alone when `character` is nil, followed by a blank line.
    private static func underlined(_ text: String, with character: Character?) -> String {
        var out = "\(text)\n"
        if let character {
            out += String(repeating: character, count: max(3, text.count)) + "\n"
        }
        return out + "\n"
    }
}
