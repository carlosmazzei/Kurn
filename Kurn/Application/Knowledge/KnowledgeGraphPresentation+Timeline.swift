import Foundation
import KurnCore

/// The Graph Explorer's evolution and compare modes (K4.3, CLAUDE.md "Knowledge
/// graph explorer (K4.3)"): the same neighbourhood, showing only the
/// relationships that held on a day, or what started, ended or held between
/// two. KurnCore's `KnowledgeGraphTimeline` decides; this reads the days in the
/// person's calendar and words the result.
extension KnowledgeGraphPresentation {
    enum GraphMode: String, CaseIterable, Identifiable, Equatable {
        case relationships, evolution, compare, lanes

        var id: String { rawValue }
        var displayName: String { copy("mode." + rawValue) }
    }

    /// What a mode says about one edge; nil in relationships mode. Each case
    /// keeps how certainly the edge held on the day or days it held.
    enum EdgeState: Equatable {
        /// Evolution: it held on the day.
        case holds(KnowledgeTemporalCertainty)
        /// Compare: it held on the later day only (with that day's certainty).
        case started(KnowledgeTemporalCertainty)
        /// Compare: it held on the earlier day only (with that day's certainty).
        case ended(KnowledgeTemporalCertainty)
        /// Compare: it held on both days.
        case kept(before: KnowledgeTemporalCertainty, after: KnowledgeTemporalCertainty)

        /// It may not have held on a day it is shown for.
        var isUncertain: Bool {
            switch self {
            case let .holds(certainty), let .started(certainty), let .ended(certainty): certainty == .possible
            case let .kept(before, after): before == .possible || after == .possible
            }
        }
    }

    /// The days a mode reads: the reader's choice, else today and, for the
    /// earlier day, the first stated start on the opened entity's page.
    struct Days: Equatable {
        let day: Date
        let from: Date
        let to: Date
    }

    static func days(_ exploration: Exploration, pages: [KnowledgeWikiPage], entityID: UUID, now: Date) -> Days {
        let earlier = pages.first { $0.entity.id == entityID }
            .map { KnowledgeComparePresentation.defaultEarlierDate(page: $0, now: now) } ?? now.addingTimeInterval(-30 * 86_400)
        return Days(day: exploration.day ?? now, from: exploration.from ?? earlier, to: exploration.to ?? now)
    }

    /// Each shown edge's state in the exploration's mode, or nil in
    /// relationships mode. An edge missing from the result is not shown.
    static func states(_ exploration: Exploration, graph: KnowledgeGraph, pages: [KnowledgeWikiPage], days: Days,
                       calendar: Calendar = .current) -> [UUID: EdgeState]? {
        let claims = { KnowledgeStateComparison.claims(from: pages) }
        switch exploration.mode {
        case .relationships, .lanes:
            return nil
        case .evolution:
            guard let moment = point(days.day, asKnownThen: exploration.asKnownThen, calendar: calendar) else { return [:] }
            return KnowledgeGraphTimeline.holdings(of: graph, at: moment, claims: claims()).mapValues { .holds($0) }
        case .compare:
            guard let from = point(min(days.from, days.to), asKnownThen: exploration.asKnownThen, calendar: calendar),
                  let to = point(max(days.from, days.to), asKnownThen: exploration.asKnownThen, calendar: calendar) else { return [:] }
            return KnowledgeGraphTimeline.compare(graph, from: from, to: to, claims: claims()).mapValues { change -> EdgeState in
                switch change.change {
                case .started: .started(change.after ?? .possible)
                case .ended: .ended(change.before ?? .possible)
                case .kept: .kept(before: change.before ?? .possible, after: change.after ?? .possible)
                }
            }
        }
    }

    /// The end of `date`'s day in `calendar`, as known then or as known now.
    static func point(_ date: Date, asKnownThen: Bool, calendar: Calendar = .current) -> KnowledgeStateComparison.Point? {
        KnowledgeComparePresentation.day(date, calendar: calendar)
            .flatMap { KnowledgeStateComparison.Point.endOfDay($0, knownAt: asKnownThen ? nil : .distantFuture) }
    }

    /// The words for an edge's state, and for its uncertainty when it may not
    /// have held; the drawing marks both with a shape too.
    static func notes(for state: EdgeState?) -> [String] {
        guard let state else { return [] }
        let change: String? = switch state {
        case .holds: nil
        case .started: copy("state.started")
        case .ended: copy("state.ended")
        case .kept: copy("state.kept")
        }
        let doubt: String? = switch state {
        case .holds: state.isUncertain ? copy("state.possible") : nil
        default: state.isUncertain ? copy("state.uncertain") : nil
        }
        return [change, doubt].compactMap { $0 }
    }

    /// What the marks mean in a mode.
    static func legend(_ mode: GraphMode) -> String? {
        mode == .relationships ? nil : copy("mode." + mode.rawValue + ".footer")
    }
}
