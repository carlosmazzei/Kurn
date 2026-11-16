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

    static func valueText(_ value: KnowledgeTypedValue) -> String {
        switch value {
        case let .string(text): text
        case let .number(number, unit): number.formatted() + (unit.map { " " + $0 } ?? "")
        case let .boolean(flag): NSLocalizedString(flag ? "knowledge.value.true" : "knowledge.value.false", comment: "Boolean value")
        case let .date(date): date.text // Keep stated precision; never invent a day/instant.
        case let .enumeration(text): NSLocalizedString("knowledge.status." + text, comment: "Claim status")
        }
    }
}
