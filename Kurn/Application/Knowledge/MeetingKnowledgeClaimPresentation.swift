import Foundation
import KurnCore

enum MeetingKnowledgeClaimPresentation {
    static func text(_ entry: KnowledgeWikiPage.Entry) -> String {
        let predicate = NSLocalizedString("knowledge.predicate." + entry.fact.predicate.rawValue, comment: "Claim predicate")
        let object = entry.object?.name ?? entry.fact.value.map(valueText) ?? ""
        let claim = String(format: NSLocalizedString("detail.knowledge.claim", comment: "Subject, predicate and object in source direction"),
            entry.subject.name, predicate, object)
        if entry.fact.qualifiers.polarity == .negative {
            return String(format: NSLocalizedString("detail.knowledge.negative_claim", comment: "Explicitly negated structured claim"), claim)
        }
        return claim
    }

    /// The meeting-tab row: one plain "<subject> <predicate> <object>"
    /// sentence — no arrow glyph, no "Not:" prefix (negation is a tag there).
    static func sentence(_ entry: KnowledgeWikiPage.Entry) -> String {
        let predicate = NSLocalizedString("knowledge.predicate." + entry.fact.predicate.rawValue, comment: "Claim predicate")
        let object = entry.object?.name ?? entry.fact.value.map(valueText) ?? ""
        return String(format: NSLocalizedString("detail.knowledge.fact_sentence", comment: "Plain fact sentence"),
            entry.subject.name, predicate, object)
    }

    static func valueText(_ value: KnowledgeTypedValue) -> String {
        switch value {
        case let .string(text): text
        case let .number(number, unit): numberText(number) + (unit.map { " " + $0 } ?? "")
        case let .boolean(flag): NSLocalizedString(flag ? "knowledge.value.true" : "knowledge.value.false", comment: "Boolean value")
        case let .date(date): date.text // Keep stated precision; never invent a day/instant.
        case let .enumeration(text): NSLocalizedString("knowledge.status." + text, comment: "Claim status")
        }
    }

    /// The default decimal format rounds to three places. Use the Double's
    /// round-trip text, localizing only its separator, so tiny/non-integer
    /// metrics cannot silently become zero or acquire a different value.
    static func numberText(_ number: Double, locale: Locale = .current) -> String {
        let text = number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        return text.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }
}
