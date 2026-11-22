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
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return Array(newest.prefix(limit).map(\.id))
        }
        let thisWeek = newest.filter { $0.createdAt >= startOfWeek && $0.createdAt <= now }
        let scope = thisWeek.isEmpty ? newest : thisWeek
        return Array(scope.prefix(limit).map(\.id))
    }
}
