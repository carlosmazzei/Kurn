//
//  MarkdownExportRenderer.swift
//  KurnCore
//
//  Markdown for an `ExportDocument`, in two flavours: plain, and Obsidian
//  (YAML frontmatter for the note's properties, speakers as `[[wikilinks]]`
//  so each person becomes a note the vault can link and back-link).
//
//  LLM-written Markdown is emitted exactly as written — this is the one
//  format where re-rendering it could only lose something.
//

import Foundation

public enum MarkdownExportRenderer {
    public static func render(_ document: ExportDocument, obsidianStyle: Bool = false) -> String {
        var out = obsidianStyle ? frontmatter(for: document) : ""
        out += "# \(document.title)\n\n"
        out += "_\(document.dateLine)_\n\n"
        if let duration = document.duration {
            out += "**\(ExportDocument.durationLabel):** \(duration)\n\n"
        }
        for block in document.blocks {
            out += render(block, obsidianStyle: obsidianStyle)
        }
        return out
    }

    private static func render(_ block: ExportDocument.Block, obsidianStyle: Bool) -> String {
        switch block {
        case .heading(let level, let text):
            return String(repeating: "#", count: max(1, level)) + " \(text)\n\n"
        case .plainText(let text), .markdown(let text):
            return "\(text)\n\n"
        case .bulletItems(let items):
            guard !items.isEmpty else { return "" }
            return items.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        case .utterance(let utterance):
            let name = obsidianStyle ? "[[\(utterance.speaker)]]" : utterance.speaker
            let prefix = utterance.isHighlighted ? "⭐ " : ""
            return "\(prefix)**[\(utterance.timestamp)] \(name):** \(utterance.text)\n\n"
        case .photo(let timestamp, let recognizedText):
            var out = "📷 [\(timestamp)]"
            if let recognizedText, !recognizedText.isEmpty {
                out += " \(recognizedText)"
            }
            return out + "\n\n"
        }
    }

    // MARK: - Frontmatter

    /// YAML frontmatter Obsidian reads as note properties. Keys whose value is
    /// absent or false are omitted rather than emitted empty, so an untagged,
    /// unfiled, non-favorite meeting carries no noise.
    static func frontmatter(for document: ExportDocument) -> String {
        let properties = document.properties
        var lines = ["title: \(yamlString(document.title))"]
        lines.append("date: \(isoDate(properties.date))")
        if !properties.tags.isEmpty {
            lines.append("tags: [\(properties.tags.map(yamlString).joined(separator: ", "))]")
        }
        if let folder = properties.folderPath {
            lines.append("folder: \(yamlString(folder))")
        }
        if properties.isFavorite {
            lines.append("favorite: true")
        }
        return "---\n" + lines.joined(separator: "\n") + "\n---\n\n"
    }

    /// A double-quoted YAML scalar, escaping what would break the block: an
    /// embedded quote or backslash, or a newline (values are single-line).
    static func yamlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    /// `yyyy-MM-dd` in the user's time zone — the day the meeting happened
    /// where it happened, which is what a daily-notes vault files it under.
    static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
