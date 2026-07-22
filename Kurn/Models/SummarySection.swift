//
//  SummarySection.swift
//  Kurn
//
//  One titled section of a generated summary. Summaries no longer have a fixed
//  shape — each template defines its own sections — so a summary is just an
//  ordered list of these. Shared across providers, the service, the persisted
//  `Summary` model, and the views.
//

import Foundation

struct SummarySection: Codable, Sendable, Hashable {
    /// Section heading, in the transcript's own language.
    var title: String
    /// Markdown paragraph(s) for the section. May be empty when the section is a
    /// pure bullet list.
    var body: String
    /// Bullet items for the section. May be empty when the section is prose only.
    var items: [String]

    init(title: String, body: String = "", items: [String] = []) {
        self.title = title
        self.body = body
        self.items = items
    }

    /// A copy with any literal `\n`/`\t` escape sequences (from a model that
    /// double-escaped its JSON) turned back into real whitespace, so the section
    /// renders and exports as intended instead of showing "\n".
    func normalizedWhitespace() -> SummarySection {
        SummarySection(
            title: title.unescapingLiteralWhitespace(),
            body: body.unescapingLiteralWhitespace(),
            items: items.map { $0.unescapingLiteralWhitespace() }
        )
    }
}
