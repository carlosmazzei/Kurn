//
//  SummaryJSON.swift
//  KurnCore
//
//  The tolerant JSON contract every cloud vendor is instructed to return for
//  summaries, plus the fence/prose-stripping parser shared by every provider's
//  `summarize` call. Split out of `Kurn/Providers/LLMProvider.swift`, which
//  keeps the network-facing `LLMProvider` protocol and `LLMHTTP` helpers —
//  this half has no URLSession dependency at all.
//

import Foundation

/// The JSON contract all vendors are instructed to return for summaries: an
/// ordered list of titled sections, each with optional prose and/or bullets.
public struct SummaryJSON: Decodable {
    public struct Section: Decodable {
        public let title: String
        public let body: String?
        public let items: [String]?

        public init(title: String, body: String? = nil, items: [String]? = nil) {
            self.title = title
            self.body = body
            self.items = items
        }
    }
    public let sections: [Section]

    /// Not just a `Decodable` conformance: `FoundationModelsProvider`'s guided
    /// generation produces a `Section` list directly (no free-text JSON to
    /// parse), and reuses this initializer to get `summarySections`'s
    /// trimming/filtering rather than duplicating it.
    public init(sections: [Section]) {
        self.sections = sections
    }

    /// Map the wire shape into the shared `SummarySection` value type, dropping
    /// sections that carry neither a title nor any content.
    public var summarySections: [SummarySection] {
        sections.compactMap { section in
            let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (section.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let items = (section.items ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !title.isEmpty || !body.isEmpty || !items.isEmpty else { return nil }
            return SummarySection(title: title, body: body, items: items)
        }
    }
}

public extension SummaryJSON {
    /// Tolerant decode that strips accidental markdown code fences before parsing.
    static func parse(_ raw: String) throws -> SummaryJSON {
        do {
            return try JSONDecoder().decode(
                SummaryJSON.self,
                from: ModelJSON.objectData(from: raw)
            )
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.decodingError(error.localizedDescription)
        }
    }
}

/// Extract a JSON object from model output while tolerating Markdown fences and
/// explanatory prose. Structured-output APIs reduce these cases but do not
/// eliminate them across all providers and model versions.
public enum ModelJSON {
    public static func objectData(from raw: String) throws -> Data {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fenceRange = text.range(of: "```", options: .backwards) {
                text = String(text[..<fenceRange.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
            return data
        }
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start < end,
           let data = String(text[start...end]).data(using: .utf8) {
            return data
        }
        throw AppError.decodingError("response did not contain a JSON object")
    }
}
