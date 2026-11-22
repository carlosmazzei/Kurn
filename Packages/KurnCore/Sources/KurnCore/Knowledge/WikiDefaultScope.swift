import Foundation

/// The wiki reader's default scope: the meetings of the current calendar
/// week, newest first, capped; when the week is empty, the newest meetings
/// overall. Selection is pure — the caller filters candidates by policy.
public enum WikiDefaultScope {
    /// - Parameters:
    ///   - candidates: `(id, createdAt)` pairs in any order.
    ///   - now: the instant the sheet opened.
    ///   - calendar: the user's calendar (week boundary is locale-dependent).
    ///   - limit: the maximum selection size.
    /// - Returns: candidate ids, newest first.
    public static func select(candidates: [(id: UUID, createdAt: Date)], now: Date,
                              calendar: Calendar = .current, limit: Int = 16) -> [UUID] {
        guard limit > 0 else { return [] }
        let newest = candidates.sorted { $0.createdAt > $1.createdAt }
        guard let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return Array(newest.prefix(limit).map(\.id))
        }
        let thisWeek = newest.filter { $0.createdAt >= startOfWeek && $0.createdAt <= now }
        let scope = thisWeek.isEmpty ? newest : thisWeek
        return Array(scope.prefix(limit).map(\.id))
    }

    /// Keeps a remembered selection only where the meetings still exist and
    /// are allowed; a fully stale selection (its meetings deleted or no
    /// longer permitted) falls back to the default `select` scope rather
    /// than leaving the reader on an empty, blocked one.
    /// - Parameters:
    ///   - selected: the remembered scope.
    ///   - candidates: `(id, createdAt)` pairs of the meetings that exist and
    ///     are allowed, in any order.
    ///   - now/calendar/limit: as in `select`.
    /// - Returns: the reconciled scope (empty when there are no candidates).
    public static func reconcile(selected: Set<UUID>,
                                 candidates: [(id: UUID, createdAt: Date)],
                                 now: Date, calendar: Calendar = .current, limit: Int = 16) -> Set<UUID> {
        let allowed = Set(candidates.map(\.id))
        let kept = selected.intersection(allowed)
        guard kept.isEmpty else { return kept }
        return Set(select(candidates: candidates, now: now, calendar: calendar, limit: limit))
    }
}
