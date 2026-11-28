//
//  KnowledgeInference+CurrentCommitments.swift
//  KurnCore
//
//  K7.4: the commitments that still stand. `deriveCommitments` lists every owner × date
//  pairing an action ever had; this drops the pairings whose owner or date a later
//  statement replaced, by stated start alone (CLAUDE.md "Knowledge derived edges (K7.4)").
//  Pure and deterministic; nothing here is evidence.
//

import Foundation

extension KnowledgeInference {
    /// The commitments left once a later statement replaces an earlier one. An owner claim is
    /// replaced by a claim naming a different owner whose stated start is wholly after its own
    /// (an assignment to someone else ends the earlier one); a due date likewise by a different
    /// date. This is the temporal reducer's rule for single-valued predicates, applied to the
    /// owner as well: assignments to different people are otherwise kept side by side. A claim
    /// with no stated start neither replaces nor is replaced, so an undated pairing is never
    /// narrowed away, and `recordedAt` and input order decide nothing. A claim with a stated end
    /// (a week's cover) replaces nothing: this reads no date, so it cannot tell whether the cover
    /// has ended, and both owners stay. A pairing that survives is
    /// still a derived, review-only suggestion: it lists the same two premises.
    ///
    /// With `now`, a claim whose stated period is not running then is left out before any of that: one
    /// that ended (an owner who stepped down) or has not begun (a later assignment) is neither a premise
    /// nor a replacement. A claim whose stated start is still within its own period at `now` stays a
    /// premise but replaces nothing until that period is over.
    public static func deriveCurrentCommitments(from allFacts: [KnowledgeWikiSnapshot.Fact],
                                                at now: Date? = nil) -> CommitmentResult {
        let facts = now.map { now in allFacts.filter { isRunning($0, at: now) } } ?? allFacts
        let premises = commitmentPremises(from: facts)
        var starts: [UUID: (lower: Date, upper: Date)] = [:]
        var ended = Set<UUID>()
        for fact in facts {
            if let bounds = fact.qualifiers.validFrom?.bounds { starts[fact.id] = bounds }
            // A claim with a stated end replaces nothing: it may already be over.
            if fact.qualifiers.validTo != nil { ended.insert(fact.id) }
            // With a clock, a start whose stated period is still running ("sometime in November") may not
            // have happened yet: the claim stays a possible premise but replaces nothing until it is over.
            if let now, let bounds = starts[fact.id], bounds.upper > now { ended.insert(fact.id) }
        }
        var owners: [UUID: [(owner: UUID, fact: UUID)]] = [:]
        for (action, items) in premises.owners {
            let replaced = replacedClaims(items.map { (statement: $0.owner.uuidString, fact: $0.fact) }, starts: starts, ended: ended)
            owners[action] = items.filter { !replaced.contains($0.fact) }
        }
        var dues: [UUID: [(due: KnowledgeTemporalValue, fact: UUID)]] = [:]
        for (action, items) in premises.dues {
            let replaced = replacedClaims(items.map { (statement: $0.due.text, fact: $0.fact) }, starts: starts, ended: ended)
            dues[action] = items.filter { !replaced.contains($0.fact) }
        }
        return join(owners: owners, dues: dues)
    }

    /// The claims some other statement replaced: one with a different statement whose stated
    /// start is wholly after this claim's own.
    private static func replacedClaims(_ items: [(statement: String, fact: UUID)],
                                       starts: [UUID: (lower: Date, upper: Date)], ended: Set<UUID>) -> Set<UUID> {
        var replaced = Set<UUID>()
        for item in items {
            guard let mine = starts[item.fact] else { continue }
            for other in items where other.statement != item.statement && !ended.contains(other.fact) {
                guard let theirs = starts[other.fact] else { continue }
                if theirs.lower >= mine.upper {
                    replaced.insert(item.fact)
                    break
                }
            }
        }
        return replaced
    }

    /// A stated period that contains `now`: begun (or undated) and not yet over (or open).
    private static func isRunning(_ fact: KnowledgeWikiSnapshot.Fact, at now: Date) -> Bool {
        if let begin = fact.qualifiers.validFrom?.bounds, begin.lower > now { return false }
        if let end = fact.qualifiers.validTo?.bounds, end.upper <= now { return false }
        return true
    }
}
