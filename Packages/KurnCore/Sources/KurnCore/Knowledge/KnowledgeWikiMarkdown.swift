import Foundation

/// All text is untrusted. Only the renderer emits typed entity/evidence links;
/// model text cannot create routes, images, HTML, headings or remote links.
enum KnowledgeWikiMarkdown {
    static func text(_ value: String) -> String {
        let collapsed = value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
        return collapsed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map { scalar in
            scalar.isASCII && punctuation.contains(scalar) ? "\\" + String(scalar) : String(scalar)
        }.joined()
    }

    static func render(_ page: KnowledgeWikiPage) -> String {
        var blocks = ["# \(text(page.entity.name))", "Kind: \(page.entity.kind.rawValue) · Canonical revision: \(page.revision)"]
        if !page.entity.aliases.isEmpty { blocks.append("Aliases: " + page.entity.aliases.map(text).joined(separator: ", ")) }
        let entries = page.sections.flatMap(\.entries)
        if let narrative = page.narrative {
            blocks += ["## Narrative", "Generated narrative; verify against the attributed claims below."]
            for paragraph in narrative.paragraphs {
                let ids = Set(paragraph.assertionIDs)
                blocks.append(text(paragraph.text) + " " + citations(entries.filter { ids.contains($0.fact.id) }.flatMap { $0.fact.source.evidence }))
            }
        }
        for section in page.sections {
            blocks.append("## " + section.kind.rawValue.capitalized)
            blocks += section.entries.map(render)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func render(_ entry: KnowledgeWikiPage.Entry) -> String {
        let fact = entry.fact
        let qualifiers = fact.qualifiers
        let object = entry.object.map(link) ?? fact.value.map(value) ?? ""
        var lines = ["- \(link(entry.subject)) · \(fact.predicate.rawValue) · \(object)"]
        lines.append("  \(qualifiers.polarity.rawValue); \(qualifiers.modality.rawValue); \(qualifiers.claimKind.rawValue); "
            + "\(qualifiers.authority.rawValue); confidence: \(qualifiers.confidence.rawValue); review: \(qualifiers.review.rawValue).")
        let start = qualifiers.validFrom.map { "\($0.text) (\($0.precision.rawValue))" } ?? "unknown"
        let end = qualifiers.validTo.map { "\($0.text) (\($0.precision.rawValue))" } ?? "unknown"
        let date = ISO8601DateFormatter().string(from: fact.source.recordedAt)
        lines.append("  Valid interval: [\(start), \(end)); learned: \(date). Assertion: \(fact.id.uuidString.lowercased()).")
        for evidence in fact.source.evidence {
            lines.append("  Claim attributed to \(text(evidence.attributedSpeaker)) · quote: \(text(evidence.quote)) " + citations([evidence]))
        }
        return lines.joined(separator: "\n")
    }

    private static func link(_ entity: KnowledgeWikiSnapshot.Entity) -> String {
        "[\(text(entity.name))](entity:\(entity.id.uuidString.lowercased()))"
    }

    private static func citations(_ evidence: [KnowledgeWikiSnapshot.Evidence]) -> String {
        evidence.map { "[evidence](evidence:\($0.id.uuidString.lowercased()))" }.joined(separator: " ")
    }

    private static func value(_ value: KnowledgeTypedValue) -> String {
        switch value {
        case let .string(string), let .enumeration(string): text(string)
        case let .number(number, unit): text(String(number) + (unit.map { " " + $0 } ?? ""))
        case let .boolean(flag): String(flag)
        case let .date(date): "\(date.text) (\(date.precision.rawValue))"
        }
    }
}
