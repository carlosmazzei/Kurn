//
//  MeetingFilter.swift
//  Kurn
//
//  Value type representing the active filters on the meetings list. Kept
//  separate from the view so it can be passed around, tested, and later
//  persisted as a Smart Folder predicate.
//

import Foundation
import SwiftData

/// Active filters applied to the meetings list. All conditions are ANDed
/// together; an empty/unset filter is a no-op.
struct MeetingFilter: Hashable, Sendable, Codable {
    var dateRange: MeetingDateFilter = .all
    var tagIDs: Set<UUID> = []
    var statuses: Set<TranscriptionStatus> = []
    var hasSummary: Bool?
    var minDuration: TimeInterval?
    var maxDuration: TimeInterval?

    /// Whether a meeting passes every active filter condition.
    func matches(_ meeting: Meeting) -> Bool {
        if !dateRange.matches(meeting.createdAt) { return false }
        if !tagIDs.isEmpty {
            let meetingTagIDs = Set(meeting.tags.map(\.id))
            if meetingTagIDs.isDisjoint(with: tagIDs) { return false }
        }
        if !statuses.isEmpty, !statuses.contains(meeting.aggregateStatus) { return false }
        if hasSummary == true && meeting.summary == nil { return false }
        if hasSummary == false && meeting.summary != nil { return false }
        let duration = meeting.totalDuration
        if let min = minDuration, duration < min { return false }
        if let max = maxDuration, duration > max { return false }
        return true
    }

    /// Whether any non-default condition is active.
    var isActive: Bool {
        dateRange != .all
        || !tagIDs.isEmpty
        || !statuses.isEmpty
        || hasSummary != nil
        || minDuration != nil
        || maxDuration != nil
    }

    /// Number of active non-default conditions (for the filter badge).
    var activeCount: Int {
        var count = 0
        if dateRange != .all { count += 1 }
        if !tagIDs.isEmpty { count += 1 }
        if !statuses.isEmpty { count += 1 }
        if hasSummary != nil { count += 1 }
        if minDuration != nil || maxDuration != nil { count += 1 }
        return count
    }
}

/// Date-range filter for the meetings list.
enum MeetingDateFilter: String, CaseIterable, Identifiable, Sendable, Codable {
    case all, today, thisWeek
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return NSLocalizedString("filter.all", comment: "All")
        case .today: return NSLocalizedString("filter.today", comment: "Today")
        case .thisWeek: return NSLocalizedString("filter.this_week", comment: "This week")
        }
    }

    func matches(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: return true
        case .today: return calendar.isDateInToday(date)
        case .thisWeek:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        }
    }
}
