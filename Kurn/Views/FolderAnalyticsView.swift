//
//  FolderAnalyticsView.swift
//  Kurn
//
//  Sheet that displays folder insights: meeting count, total/average duration,
//  transcription status breakdown, popular tags, and top speakers.
//

import SwiftData
import SwiftUI

struct FolderAnalyticsView: View {
    @Environment(\.dismiss) private var dismiss

    let folder: Folder?
    let meetings: [Meeting]

    var body: some View {
        NavigationStack {
            List {
                overviewSection
                statusSection
                tagSection
                speakerSection
            }
            .navigationTitle(
                folder?.name ?? NSLocalizedString("analytics.all_meetings", comment: "All Meetings")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
    }

    private var analytics: FolderAnalytics {
        FolderAnalytics(meetings: meetings)
    }

    private var overviewSection: some View {
        Section(NSLocalizedString("analytics.overview", comment: "Overview")) {
            LabeledContent(
                NSLocalizedString("analytics.meeting_count", comment: "Meetings"),
                value: "\(analytics.meetingCount)"
            )
            LabeledContent(
                NSLocalizedString("analytics.total_duration", comment: "Total duration"),
                value: analytics.totalDuration.clockDisplay
            )
            LabeledContent(
                NSLocalizedString("analytics.average_duration", comment: "Average duration"),
                value: analytics.averageDuration.clockDisplay
            )
        }
    }

    private var statusSection: some View {
        Section(NSLocalizedString("analytics.status", comment: "Transcription status")) {
            ForEach(TranscriptionStatus.allCases) { status in
                let count = analytics.statusCounts[status] ?? 0
                HStack {
                    Text(status.displayName)
                    Spacer()
                    Text("\(count)")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var tagSection: some View {
        Section(NSLocalizedString("analytics.popular_tags", comment: "Popular tags")) {
            if analytics.tagCounts.isEmpty {
                Text(NSLocalizedString("tag.empty", comment: "No tags"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(analytics.tagCounts, id: \.tag.id) { entry in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(hex: entry.tag.colorHex))
                            .frame(width: 10, height: 10)
                        Text(entry.tag.name)
                        Spacer()
                        Text("\(entry.count)")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private var speakerSection: some View {
        Section(NSLocalizedString("analytics.top_speakers", comment: "Top speakers")) {
            if analytics.topSpeakers.isEmpty {
                Text(NSLocalizedString("analytics.no_speakers", comment: "No speakers"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(analytics.topSpeakers, id: \.speaker.id) { entry in
                    HStack {
                        Text(entry.speaker.displayName)
                        Spacer()
                        Text("\(entry.count)")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }
}
