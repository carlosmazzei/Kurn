//
//  MeetingFilter.swift
//  KurnCore
//
//  Value type representing the active filters on the meetings list. Kept
//  separate from the view so it can be passed around, tested, and later
//  persisted as a Smart Folder predicate.
//
//  `matches(_:)` takes a `MeetingFilterAttributes` snapshot rather than the
//  app's SwiftData `Meeting` class directly, so this whole type — including
//  the matching logic — stays Foundation-only and testable without SwiftData
//  or a `ModelContext`. The app supplies the SwiftData-facing half as a
//  `Meeting`-accepting overload (`Kurn/Models/MeetingFilter+Meeting.swift`).
//

import Foundation

/// Everything `MeetingFilter.matches` needs off a `Meeting`, without
/// depending on SwiftData or the `Meeting` class itself.
public struct MeetingFilterAttributes: Sendable {
    public var tagIDs: Set<UUID>
    public var status: TranscriptionStatus
    public var createdAt: Date
    public var hasSummary: Bool
    public var totalDuration: TimeInterval

    public init(
        tagIDs: Set<UUID>,
        status: TranscriptionStatus,
        createdAt: Date,
        hasSummary: Bool,
        totalDuration: TimeInterval
    ) {
        self.tagIDs = tagIDs
        self.status = status
        self.createdAt = createdAt
        self.hasSummary = hasSummary
        self.totalDuration = totalDuration
    }
}

/// Active filters applied to the meetings list. All conditions are ANDed
/// together; an empty/unset filter is a no-op.
public struct MeetingFilter: Hashable, Sendable, Codable {
    public var dateRange: MeetingDateFilter = .all
    public var tagIDs: Set<UUID> = []
    public var statuses: Set<TranscriptionStatus> = []
    public var hasSummary: Bool?
    public var minDuration: TimeInterval?
    public var maxDuration: TimeInterval?

    public init(
        dateRange: MeetingDateFilter = .all,
        tagIDs: Set<UUID> = [],
        statuses: Set<TranscriptionStatus> = [],
        hasSummary: Bool? = nil,
        minDuration: TimeInterval? = nil,
        maxDuration: TimeInterval? = nil
    ) {
        self.dateRange = dateRange
        self.tagIDs = tagIDs
        self.statuses = statuses
        self.hasSummary = hasSummary
        self.minDuration = minDuration
        self.maxDuration = maxDuration
    }

    /// Whether a meeting passes every active filter condition.
    public func matches(_ attributes: MeetingFilterAttributes) -> Bool {
        if !dateRange.matches(attributes.createdAt) { return false }
        if !tagIDs.isEmpty {
            if tagIDs.isDisjoint(with: attributes.tagIDs) { return false }
        }
        if !statuses.isEmpty, !statuses.contains(attributes.status) { return false }
        if hasSummary == true && !attributes.hasSummary { return false }
        if hasSummary == false && attributes.hasSummary { return false }
        let duration = attributes.totalDuration
        if let min = minDuration, duration < min { return false }
        if let max = maxDuration, duration > max { return false }
        return true
    }

    /// Whether any non-default condition is active.
    public var isActive: Bool {
        dateRange != .all
        || !tagIDs.isEmpty
        || !statuses.isEmpty
        || hasSummary != nil
        || minDuration != nil
        || maxDuration != nil
    }

    /// Number of active non-default conditions (for the filter badge).
    public var activeCount: Int {
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
public enum MeetingDateFilter: String, CaseIterable, Identifiable, Sendable, Codable {
    case all, today, thisWeek
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return NSLocalizedString("filter.all", comment: "All")
        case .today: return NSLocalizedString("filter.today", comment: "Today")
        case .thisWeek: return NSLocalizedString("filter.this_week", comment: "This week")
        }
    }

    public func matches(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all: return true
        case .today: return calendar.isDateInToday(date)
        case .thisWeek:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        }
    }
}
