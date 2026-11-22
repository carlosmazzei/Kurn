//
//  KnowledgeLateArrival.swift
//  KurnCore
//
//  K3.5: what a late arrival changed (CLAUDE.md "Knowledge late arrivals
//  (K3.5)"). Claims recorded together (one transaction time) arrive late for an
//  entity when the store already knew something about it and they change what
//  held on a day before the one they were recorded on. Only the affected valid
//  interval is recomputed: from the earliest moment the new claims could hold,
//  the K3.1 state as known just before the arrival is compared with the state as
//  known at it, at each moment a stated bound could change it, and the stretches
//  that differ are returned. Nothing is stored or rewritten.
//

import Foundation

public struct KnowledgeLateArrival: Equatable, Sendable {
    /// A stretch of valid time in which the arrival changed the state the same way.
    public struct Segment: Equatable, Sendable {
        public let lower: Date
        /// The next moment the change differs; nil while it lasts.
        public let upper: Date?
        /// The state at `lower` as known just before the arrival against as
        /// known at it.
        public let comparison: KnowledgeStateComparison

        public init(lower: Date, upper: Date?, comparison: KnowledgeStateComparison) {
            self.lower = lower
            self.upper = upper
            self.comparison = comparison
        }
    }

    public let entityID: UUID
    /// The arrival's transaction time.
    public let arrivedAt: Date
    /// The claims recorded at `arrivedAt` that name the entity.
    public let claimIDs: [UUID]
    /// Stretches where what held changed, in valid-time order.
    public let segments: [Segment]

    /// The first moment whose state the arrival changed.
    public var affectedFrom: Date? { segments.first?.lower }

    /// Every arrival that revised what was already known about `entityID`'s
    /// past, oldest first.
    public static func revisions(of entityID: UUID, claims: [KnowledgeTemporalClaim]) -> [KnowledgeLateArrival] {
        let touching = claims.filter { $0.subjectID == entityID || $0.objectID == entityID }
        let times = Set(touching.map(\.recordedAt)).sorted()
        return times.compactMap { recompute(entityID: entityID, arrivedAt: $0, claims: claims) }
    }

    /// What the claims recorded at `arrivedAt` changed for `entityID`, or nil
    /// when nothing was known before them, they change nothing, or they only
    /// change their own recording day or later.
    public static func recompute(entityID: UUID, arrivedAt: Date, claims: [KnowledgeTemporalClaim]) -> KnowledgeLateArrival? {
        let touching = claims.filter { $0.subjectID == entityID || $0.objectID == entityID }
        let arrived = touching.filter { $0.recordedAt == arrivedAt }
        guard !arrived.isEmpty, touching.contains(where: { $0.recordedAt < arrivedAt }) else { return nil }
        let before = Date(timeIntervalSinceReferenceDate: arrivedAt.timeIntervalSinceReferenceDate.nextDown)
        // A claim with no stated start holds (possibly) at every moment, so it
        // reaches back as far as anything known about the entity.
        let bounds = touching.flatMap(Self.bounds).sorted()
        let starts = arrived.map { $0.validFrom?.bounds?.lower ?? bounds.first ?? arrivedAt }
        guard let from = starts.min() else { return nil }
        let checkpoints = ([from] + bounds.filter { $0 > from }).reduce(into: [Date]()) { result, moment in
            if result.last != moment { result.append(moment) }
        }
        var segments: [Segment] = []
        var lastIdentity: [String]?
        for (index, moment) in checkpoints.enumerated() {
            let comparison = KnowledgeStateComparison.compare(
                entityID: entityID,
                earlier: .init(validAt: moment, knownAt: before), later: .init(validAt: moment, knownAt: arrivedAt),
                claims: touching)
            let identity = Self.identity(comparison)
            let upper = index + 1 < checkpoints.count ? checkpoints[index + 1] : nil
            if identity.isEmpty {
                lastIdentity = nil
                continue
            }
            if identity == lastIdentity, let last = segments.last {
                segments[segments.count - 1] = Segment(lower: last.lower, upper: upper, comparison: last.comparison)
            } else {
                segments.append(Segment(lower: moment, upper: upper, comparison: comparison))
            }
            lastIdentity = identity
        }
        // Not late: everything it changed starts on or after the day it was recorded.
        guard let first = segments.first, first.lower < Self.startOfDay(arrivedAt) else { return nil }
        return KnowledgeLateArrival(entityID: entityID, arrivedAt: arrivedAt,
                                    claimIDs: arrived.map(\.id).sorted { $0.uuidString < $1.uuidString }, segments: segments)
    }

    /// Every moment a claim's stated bounds can change what it holds.
    private static func bounds(_ claim: KnowledgeTemporalClaim) -> [Date] {
        [claim.validFrom?.bounds, claim.validTo?.bounds].compactMap { $0 }.flatMap { [$0.lower, $0.upper] }
    }

    /// What differs, by the claims on each side, so that a change that only
    /// grows certain stays one stretch.
    private static func identity(_ comparison: KnowledgeStateComparison) -> [String] {
        comparison.changes.filter { $0.kind != .unchanged || $0.certaintyChanged }.map { change in
            [change.kind.rawValue,
             (change.before?.claimIDs ?? []).map(\.uuidString).joined(separator: ","),
             (change.after?.claimIDs ?? []).map(\.uuidString).joined(separator: ",")].joined(separator: "|")
        }
    }

    private static func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") { calendar.timeZone = utc }
        return calendar.startOfDay(for: date)
    }
}
