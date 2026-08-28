//
//  MeetingFilter+Meeting.swift
//  Kurn
//
//  Adapter between `KurnCore.MeetingFilter`'s pure predicate and the app's
//  SwiftData `Meeting` class. `MeetingFilter` itself, and the attributes it
//  matches against, are Foundation-only and live in KurnCore; only the
//  translation from a live `Meeting` into a `MeetingFilterAttributes`
//  snapshot needs SwiftData, so it stays here.
//

import Foundation
import KurnCore

extension MeetingFilter {
    /// Same signature every existing call site already uses — only the
    /// implementation moved into the pure `matches(_:)` overload above.
    func matches(_ meeting: Meeting) -> Bool {
        matches(MeetingFilterAttributes(
            tagIDs: Set(meeting.tags.map(\.id)),
            status: meeting.aggregateStatus,
            createdAt: meeting.createdAt,
            hasSummary: !meeting.summaries.isEmpty,
            totalDuration: meeting.totalDuration
        ))
    }
}
