import Foundation
import KurnCore

/// Words, dates and links for comparing an entity between two days (K3.4,
/// CLAUDE.md "Knowledge comparison (K3.4)"). The days the person picks are read
/// in their own calendar and compared at the end of each day; nothing here
/// decides what changed, `KnowledgeStateComparison` does.
enum KnowledgeComparePresentation {
    struct Row: Equatable {
        let text: String
        /// What it was before, for a change.
        let before: String?
        let notes: [String]
        let evidence: KnowledgeBrowserRoute?
    }

    struct Section: Equatable {
        let kind: KnowledgeStateComparison.ChangeKind
        let title: String
        let rows: [Row]
    }

    /// The day `date` falls on in `calendar`, as a stated day.
    static func day(_ date: Date, calendar: Calendar = .current) -> KnowledgeTemporalValue? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return KnowledgeTemporalValue(text: String(format: "%04d-%02d-%02d", year, month, day), precision: .day)
    }

    /// The comparison of `entityID` between the ends of two days, as known now
    /// or, with `asKnownThen`, as known at the end of each day.
    static func compare(entityID: UUID, from earlier: Date, to later: Date, asKnownThen: Bool, pages: [KnowledgeWikiPage],
                        calendar: Calendar = .current) -> KnowledgeStateComparison? {
        let first = min(earlier, later), second = max(earlier, later)
        guard let firstDay = day(first, calendar: calendar), let secondDay = day(second, calendar: calendar),
              let from = KnowledgeStateComparison.Point.endOfDay(firstDay, knownAt: asKnownThen ? nil : .distantFuture),
              let to = KnowledgeStateComparison.Point.endOfDay(secondDay, knownAt: asKnownThen ? nil : .distantFuture)
        else { return nil }
        return KnowledgeStateComparison.compare(entityID: entityID, earlier: from, later: to,
                                                claims: KnowledgeStateComparison.claims(from: pages))
    }

    /// The earliest stated start among the page's claims, else a month before
    /// `now`; the later day is today.
    static func defaultEarlierDate(page: KnowledgeWikiPage, now: Date) -> Date {
        page.sections.flatMap(\.entries).compactMap { $0.fact.qualifiers.validFrom?.bounds?.lower }.min()
            ?? now.addingTimeInterval(-30 * 86_400)
    }

    static func sections(_ comparison: KnowledgeStateComparison, pages: [KnowledgeWikiPage]) -> [Section] {
        let names = Dictionary(pages.flatMap { page in
            [(page.entity.id, page.entity.name)] + page.sections.flatMap(\.entries).flatMap { entry in
                [(entry.subject.id, entry.subject.name)] + (entry.object.map { [($0.id, $0.name)] } ?? [])
            }
        }, uniquingKeysWith: { first, _ in first })
        let evidence = Dictionary(pages.flatMap(\.sections).flatMap(\.entries).compactMap { entry in
            entry.fact.source.evidence.first.map { (entry.fact.id, $0.id) }
        }, uniquingKeysWith: { first, _ in first })
        let entityName = names[comparison.entityID] ?? ""
        return KnowledgeStateComparison.ChangeKind.allCases.compactMap { kind in
            let rows = comparison.changes.filter { $0.kind == kind }.compactMap { change -> Row? in
                guard let shown = change.after ?? change.before else { return nil }
                let claimID = shown.claimIDs.first
                let before = kind == .changed ? change.before.map { text($0, entityName: entityName, names: names) } : nil
                return Row(text: text(shown, entityName: entityName, names: names),
                           before: before.map { String(format: copy("before"), $0) },
                           notes: notes(change),
                           evidence: claimID.flatMap { id in evidence[id].map { .evidence(assertionID: id, evidenceID: $0) } })
            }
            return rows.isEmpty ? nil : Section(kind: kind, title: copy("kind." + kind.rawValue), rows: rows)
        }
    }

    /// A holding in the reader's claim form, in its original direction.
    static func text(_ holding: KnowledgeTemporalState.Holding, entityName: String, names: [UUID: String]) -> String {
        let predicate = NSLocalizedString("knowledge.predicate." + holding.predicate.rawValue, comment: "Claim predicate")
        let other = holding.otherEntityID.map { names[$0] ?? "" }
            ?? holding.value.map(MeetingKnowledgeClaimPresentation.valueText) ?? ""
        let format = NSLocalizedString("detail.knowledge.claim", comment: "Subject, predicate and object in source direction")
        let claim = holding.direction == .outgoing
            ? String(format: format, entityName, predicate, other)
            : String(format: format, other, predicate, entityName)
        guard holding.polarity == .negative else { return claim }
        return String(format: NSLocalizedString("detail.knowledge.negative_claim", comment: "Explicitly negated structured claim"), claim)
    }

    static func notes(_ change: KnowledgeStateComparison.Change) -> [String] {
        var notes: [String] = []
        if let holding = change.after ?? change.before {
            if holding.isTentative { notes.append(KnowledgeTimelinePresentation.text("tentative")) }
            if holding.certainty == .possible { notes.append(copy("possible")) }
        }
        if change.certaintyChanged { notes.append(copy("certainty_changed")) }
        return notes
    }

    static func copy(_ key: String) -> String { NSLocalizedString("knowledge.compare." + key, comment: "Knowledge comparison") }
}
