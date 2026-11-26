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
