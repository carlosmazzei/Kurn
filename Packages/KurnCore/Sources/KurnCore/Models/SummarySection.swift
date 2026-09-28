//
//  SummarySection.swift
//  KurnCore
//
//  One titled section of a generated summary. Summaries no longer have a fixed
//  shape — each template defines its own sections — so a summary is just an
//  ordered list of these. Shared across providers, the service, the persisted
//  `Summary` model, and the views.
//

import Foundation

public struct SummarySection: Codable, Sendable, Hashable {
    /// Section heading, in the transcript's own language.
    public var title: String
    /// Markdown paragraph(s) for the section. May be empty when the section is a
    /// pure bullet list.
    public var body: String
    /// Bullet items for the section. May be empty when the section is prose only.
    public var items: [String]
    /// Meeting-relative timestamps of photos this section draws on — a photo's
    /// OCR text is threaded into the transcript-assembly prompt as a
    /// "[mm:ss] 📷 Photo: …" line (see `SummaryService.assembleTranscriptText`),
    /// and the model is asked to list back the stamps of any it used. Lets the
    /// UI offer a tappable "see photo" reference instead of leaving that
    /// provenance invisible in the generated prose. Empty for sections with no
    /// photo grounding, and decoded via `decodeIfPresent` so summaries stored
    /// before this field existed still decode cleanly.
    public var photoTimestamps: [TimeInterval]

    public init(title: String, body: String = "", items: [String] = [], photoTimestamps: [TimeInterval] = []) {
        self.title = title
        self.body = body
        self.items = items
        self.photoTimestamps = photoTimestamps
    }

    private enum CodingKeys: String, CodingKey {
        case title, body, items, photoTimestamps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        items = try container.decode([String].self, forKey: .items)
        photoTimestamps = try container.decodeIfPresent([TimeInterval].self, forKey: .photoTimestamps) ?? []
    }

    /// A copy with any literal `\n`/`\t` escape sequences (from a model that
    /// double-escaped its JSON) turned back into real whitespace, so the section
    /// renders and exports as intended instead of showing "\n".
    public func normalizedWhitespace() -> SummarySection {
        SummarySection(
            title: title.unescapingLiteralWhitespace(),
            body: body.unescapingLiteralWhitespace(),
            items: items.map { $0.unescapingLiteralWhitespace() },
            photoTimestamps: photoTimestamps
        )
    }
}
