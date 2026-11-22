//
//  DaySections.swift
//  KurnCore
//
//  Groups an already-ordered list into one section per calendar day. Used by
//  the meetings list's date sort orders; grouping never re-sorts, so the
//  caller's order is preserved within and across the sections it produces.
//

import Foundation

/// One calendar day's worth of items from `DaySections.group`.
///
/// Deliberately non-Sendable: the app groups SwiftData `Meeting` models,
/// which cannot cross actor boundaries anyway.
public struct DaySection<T> {
    /// The start-of-day `Date` every item in `items` falls on.
    public let day: Date
    /// The items on that day, in the order `group` received them.
    public let items: [T]

    public init(day: Date, items: [T]) {
        self.day = day
        self.items = items
    }
}

public enum DaySections {
    /// Groups `items` by the calendar day `date` reports, preserving input
    /// order: items that arrive already sorted produce sections sorted the
    /// same way. Days are keyed by `calendar`'s `startOfDay`.
    public static func group<T>(
        _ items: [T],
        date: (T) -> Date,
        calendar: Calendar = .current
    ) -> [DaySection<T>] {
        var order: [Date] = []
        var byDay: [Date: [T]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: date(item))
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(item)
        }
        return order.map { DaySection(day: $0, items: byDay[$0] ?? []) }
    }
}
