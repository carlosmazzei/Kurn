import Foundation

/// The third clock (K7.1). A claim has a stated valid time, a transaction time (when the store learned it, set when
/// its meeting is compiled into knowledge) and a source time (`observedAt`, when it was said: the date of the meeting
/// its evidence quotes). A meeting imported long after it happened therefore changes what was *known* only from its
/// import, yet "what had been said by then" must still include it. The three are never mixed: this filter reads only
/// `observedAt`, the reducer only the other two.
public enum KnowledgeObservedTime {
    /// The claims said in a meeting held at or before `cutoff`. A claim whose source time is unknown is left out:
    /// nothing says it had been said by then.
    public static func saidBy(_ cutoff: Date, in claims: [KnowledgeTemporalClaim]) -> [KnowledgeTemporalClaim] {
        claims.filter { claim in claim.observedAt.map { $0 <= cutoff } ?? false }
    }

    /// The claims whose source time is unknown, which `saidBy` cannot place and a reader should say so about.
    public static func unplaced(in claims: [KnowledgeTemporalClaim]) -> [KnowledgeTemporalClaim] {
        claims.filter { $0.observedAt == nil }
    }
}

extension KnowledgeObservedTime {
    /// Pages restricted to what had been said by a date (K7.1 `as_of`).
    public struct Restriction: Equatable, Sendable {
        /// Only the claims said by the cutoff, without generated narratives (they summarize every meeting, so
        /// none can be trusted to describe an earlier state). A page left with no claim is dropped.
        public let pages: [KnowledgeWikiPage]
        /// Distinct claims kept, said in a later meeting, and with no known meeting date.
        public let shown: Int
        public let hiddenLater: Int
        public let hiddenUnplaced: Int
    }

    /// The last second of a stated UTC day: the inclusive cutoff `saidBy` uses for an `as_of` day.
    public static func endOfDay(_ day: KnowledgeTemporalValue) -> Date? {
        guard day.precision == .day, let upper = day.bounds?.upper else { return nil }
        return upper.addingTimeInterval(-1)
    }

    /// Restricts `pages` to the claims whose meeting was held at or before `cutoff`. A claim shown on two pages
    /// (as subject and as object) is counted once; a claim with an unknown source time is left out and counted.
    public static func restricting(_ pages: [KnowledgeWikiPage], saidBy cutoff: Date) -> Restriction {
        var kept = Set<UUID>(), later = Set<UUID>(), unplaced = Set<UUID>()
        var result: [KnowledgeWikiPage] = []
        for page in pages {
            var sections: [KnowledgeWikiPage.Section] = []
            for section in page.sections {
                var entries: [KnowledgeWikiPage.Entry] = []
                for entry in section.entries {
                    let id = entry.fact.id
                    guard let observed = entry.fact.source.observedAt else {
                        unplaced.insert(id)
                        continue
                    }
                    if observed <= cutoff {
                        kept.insert(id)
                        entries.append(entry)
                    } else {
                        later.insert(id)
                    }
                }
                if !entries.isEmpty { sections.append(KnowledgeWikiPage.Section(kind: section.kind, entries: entries)) }
            }
            if !sections.isEmpty {
                result.append(KnowledgeWikiPage(entity: page.entity, revision: page.revision, sections: sections, narrative: nil))
            }
        }
        return Restriction(pages: result, shown: kept.count, hiddenLater: later.count, hiddenUnplaced: unplaced.count)
    }
}
