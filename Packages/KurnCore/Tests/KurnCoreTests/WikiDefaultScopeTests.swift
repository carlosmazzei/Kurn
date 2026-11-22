import Foundation
import Testing
@testable import KurnCore

@Suite("WikiDefaultScope")
struct WikiDefaultScopeTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_763_500_000)

    private var weekStart: Date { calendar.dateInterval(of: .weekOfYear, for: now)!.start }

    private func candidate(at date: Date) -> (id: UUID, createdAt: Date) { (UUID(), date) }

    @Test func selectsThisWeekNewestFirst() {
        let a = candidate(at: weekStart + 3_600)
        let b = candidate(at: now - 60)
        let old = candidate(at: weekStart - 3_600)
        let selected = WikiDefaultScope.select(candidates: [a, old, b], now: now, calendar: calendar)
        #expect(selected == [b.id, a.id])
    }

    @Test func fallsBackToNewestWhenWeekIsEmpty() {
        let a = candidate(at: weekStart - 3_600)
        let b = candidate(at: weekStart - 86_400 * 10)
        let selected = WikiDefaultScope.select(candidates: [b, a], now: now, calendar: calendar)
        #expect(selected == [a.id, b.id])
    }

    @Test func capsAtLimit() {
        let candidates = (0..<20).map { candidate(at: weekStart + Double($0) * 60) }
        let selected = WikiDefaultScope.select(candidates: candidates, now: now, calendar: calendar, limit: 16)
        #expect(selected.count == 16)
    }

    @Test func emptyCandidatesReturnEmpty() {
        #expect(WikiDefaultScope.select(candidates: [], now: now, calendar: calendar).isEmpty)
    }
}
