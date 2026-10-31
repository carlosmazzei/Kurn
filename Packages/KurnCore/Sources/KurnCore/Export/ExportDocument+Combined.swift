//
//  ExportDocument+Combined.swift
//  KurnCore
//
//  Several meetings exported as one document: each meeting becomes a
//  top-level section carrying its own title, date and duration, followed by
//  its blocks exactly as its standalone export would have them. Built from the
//  per-meeting documents rather than from the meetings, so every format that
//  renders one meeting renders the collection with no code of its own.
//

import Foundation

extension ExportDocument {
    /// `parts` merged in the order given, under `title` and `dateLine`.
    ///
    /// Each part keeps the headings it already has (level 2 and below), so its
    /// own title is the one level-1 heading that separates it from the next.
    /// The collection's labels — duration, language metadata — are the first
    /// part's: a part's own headings were already written in its language.
    public static func combining(_ parts: [ExportDocument], title: String, dateLine: String) -> ExportDocument {
        var tags: [String] = []
        for tag in parts.flatMap(\.properties.tags) where !tags.contains(tag) {
            tags.append(tag)
        }
        var combined = ExportDocument(
            title: title,
            dateLine: dateLine,
            properties: Properties(
                date: parts.map(\.properties.date).min() ?? Date(timeIntervalSince1970: 0),
                tags: tags
            ),
            labels: parts.first?.labels ?? .english
        )
        for part in parts {
            combined.blocks.append(.heading(level: 1, text: part.title))
            combined.blocks.append(.markdown(partHeaderLine(part)))
            combined.blocks += part.blocks
        }
        return combined
    }

    /// `_date_ · **Duration:** 12:00`, the line a standalone export puts under
    /// its title. Markdown, so every format styles it the way it styles the
    /// standalone one.
    static func partHeaderLine(_ part: ExportDocument) -> String {
        var line = "_\(part.dateLine)_"
        if let duration = part.duration {
            line += " · **\(part.labels.duration):** \(duration)"
        }
        return line
    }
}
