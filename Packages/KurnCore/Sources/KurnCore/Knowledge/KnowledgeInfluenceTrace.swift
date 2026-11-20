import Foundation

/// `trace_influence` (K5.1): the chain behind an entity's current state, in the order it was stated —
/// every claim about the entity or naming it, which earlier claims each one replaces, and the
/// meetings, speakers and evidence passages it came from. A projection of authorized pages only.
public enum KnowledgeInfluenceTrace {
    public struct Step: Equatable, Sendable {
        public let entry: KnowledgeWikiPage.Entry
        /// Earlier steps on the same subject and predicate, newest first: the claims this one updates.
        public let replaces: [UUID]
        /// Distinct speakers of its evidence, in evidence order.
        public let speakers: [String]
    }

    public static func trace(entityID: UUID, pages: [KnowledgeWikiPage]) -> [Step] {
        var seen = Set<UUID>()
        let entries = pages.flatMap { $0.sections.flatMap(\.entries) }.filter {
            ($0.fact.subjectID == entityID || $0.fact.objectID == entityID) && seen.insert($0.fact.id).inserted
        }.sorted(by: precedes)
        var steps: [Step] = []
        for entry in entries {
            let replaced = steps.reversed().filter {
                $0.entry.fact.subjectID == entry.fact.subjectID && $0.entry.fact.predicate == entry.fact.predicate
            }.map(\.entry.fact.id)
            var speakers: [String] = []
            for evidence in entry.fact.source.evidence where !speakers.contains(evidence.attributedSpeaker) {
                speakers.append(evidence.attributedSpeaker)
            }
            steps.append(Step(entry: entry, replaces: replaced, speakers: speakers))
        }
        return steps
    }

    /// Stated time (its lower bound, else when it was recorded), then recorded time, then ID.
    static func precedes(_ lhs: KnowledgeWikiPage.Entry, _ rhs: KnowledgeWikiPage.Entry) -> Bool {
        func stated(_ entry: KnowledgeWikiPage.Entry) -> Date {
            entry.fact.qualifiers.validFrom?.bounds?.lower ?? entry.fact.source.recordedAt
        }
        let left = (stated(lhs), lhs.fact.source.recordedAt), right = (stated(rhs), rhs.fact.source.recordedAt)
        if left != right { return left < right }
        return lhs.fact.id.uuidString < rhs.fact.id.uuidString
    }
}
