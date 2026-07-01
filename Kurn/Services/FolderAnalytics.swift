//
//  FolderAnalytics.swift
//  Kurn
//
//  Computes lightweight, user-facing insights for a folder or any set of meetings:
//  counts, durations, transcription status breakdown, tag distribution, and top
//  speakers. Pure value-in / value-out so it can be used from SwiftUI or tests.
//

import Foundation

struct FolderAnalytics {
    let meetingCount: Int
    let totalDuration: TimeInterval
    let averageDuration: TimeInterval
    let statusCounts: [TranscriptionStatus: Int]
    let tagCounts: [(tag: Tag, count: Int)]
    let topSpeakers: [(speaker: Speaker, count: Int)]
    let meetingCountByWeek: [Date: Int]

    init(meetings: [Meeting]) {
        self.meetingCount = meetings.count
        self.totalDuration = meetings.reduce(0) { $0 + $1.totalDuration }
        self.averageDuration = meetingCount > 0 ? totalDuration / Double(meetingCount) : 0
        self.statusCounts = Dictionary(
            grouping: meetings,
            by: \.aggregateStatus
        ).mapValues { $0.count }
        var tagMap: [Tag: Int] = [:]
        for meeting in meetings {
            for tag in meeting.tags {
                tagMap[tag, default: 0] += 1
            }
        }
        self.tagCounts = tagMap
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
        var speakerMap: [Speaker: Int] = [:]
        for meeting in meetings {
            for speaker in meeting.speakers {
                speakerMap[speaker, default: 0] += 1
            }
        }
        self.topSpeakers = speakerMap
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { ($0.key, $0.value) }
        var weekMap: [Date: Int] = [:]
        let calendar = Calendar.current
        for meeting in meetings {
            guard let startOfWeek = calendar.date(
                from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: meeting.createdAt)
            ) else { continue }
            weekMap[startOfWeek, default: 0] += 1
        }
        self.meetingCountByWeek = weekMap
    }
}
