import Foundation
import KurnCore

/// Words and dates for the late arrivals an entity page shows (K3.5, CLAUDE.md
/// "Knowledge late arrivals (K3.5)"). KurnCore's `KnowledgeLateArrival` decides
/// what was revised; this only names it. Stated days are UTC, like every stated
/// date; the recording time is shown in the person's time zone.
enum KnowledgeLateArrivalPresentation {
    struct Stretch: Equatable {
        let title: String
        let rows: [KnowledgeComparePresentation.Row]
    }

    struct Item: Equatable {
        let title: String
        let stretches: [Stretch]
    }

    /// The page's late arrivals, oldest first. A page holds every claim about
    /// its entity, in both directions, so it is all the input needed.
    static func items(page: KnowledgeWikiPage, locale: Locale = .current, timeZone: TimeZone = .current) -> [Item] {
        let claims = KnowledgeStateComparison.claims(from: [page])
        return KnowledgeLateArrival.revisions(of: page.entity.id, claims: claims).map { late in
            Item(title: String(format: copy("recorded"), format(late.arrivedAt, locale: locale, timeZone: timeZone)),
                 stretches: late.segments.map { segment in
                     Stretch(title: range(segment, locale: locale),
                             rows: rows(segment.comparison, page: page))
                 })
        }
    }

    /// What differs in a stretch: every change, and an unchanged statement only
    /// when the arrival made it more or less certain. Each row leads its notes
    /// with what happened to it (changed, started, ended, unchanged), since the
    /// rows of a stretch are listed together without section headers.
    static func rows(_ comparison: KnowledgeStateComparison, page: KnowledgeWikiPage) -> [KnowledgeComparePresentation.Row] {
        let shifted = KnowledgeComparePresentation.copy("certainty_changed")
        return KnowledgeComparePresentation.sections(comparison, pages: [page]).flatMap { section in
            (section.kind == .unchanged ? section.rows.filter { $0.notes.contains(shifted) } : section.rows).map { row in
                KnowledgeComparePresentation.Row(text: row.text, before: row.before, notes: [section.title] + row.notes,
                                                 evidence: row.evidence)
            }
        }
    }

    /// "From <day>" while it lasts, else "From <day> until <last day>", in UTC.
    static func range(_ segment: KnowledgeLateArrival.Segment, locale: Locale = .current) -> String {
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        let from = format(segment.lower, locale: locale, timeZone: utc)
        guard let upper = segment.upper else { return String(format: copy("from"), from) }
        let last = format(upper.addingTimeInterval(-1), locale: locale, timeZone: utc)
        return last == from ? String(format: copy("on"), from) : String(format: copy("range"), from, last)
    }

    static func copy(_ key: String) -> String { NSLocalizedString("knowledge.late." + key, comment: "Knowledge late arrivals") }

    private static func format(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
