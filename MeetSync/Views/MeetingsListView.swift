//
//  MeetingsListView.swift
//  MeetSync
//
//  Lists all meetings (most recent first) with status/summary indicators, swipe
//  to delete (confirmed), and entry points for creating a meeting or opening
//  settings.
//

import SwiftData
import SwiftUI

struct MeetingsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]

    @State private var showingNewMeeting = false
    @State private var showingSettings = false
    @State private var pendingDelete: Meeting?

    var body: some View {
        List {
            ForEach(meetings) { meeting in
                NavigationLink(value: meeting) {
                    MeetingRow(meeting: meeting)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        pendingDelete = meeting
                    } label: {
                        Label(
                            NSLocalizedString("common.delete", comment: "Delete"),
                            systemImage: "trash"
                        )
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("meetings.title", comment: "Meetings"))
        .navigationDestination(for: Meeting.self) { meeting in
            MeetingDetailView(meeting: meeting)
        }
        .overlay {
            if meetings.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("meetings.empty.title", comment: "No meetings"),
                    systemImage: "mic.fill",
                    description: Text(NSLocalizedString("meetings.empty.subtitle", comment: ""))
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewMeeting = true
                } label: {
                    Label(
                        NSLocalizedString("meetings.new", comment: "New Meeting"),
                        systemImage: "plus"
                    )
                }
            }
        }
        .sheet(isPresented: $showingNewMeeting) {
            NavigationStack {
                MeetingFormView()
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
            }
        }
        .confirmationDialog(
            NSLocalizedString("meetings.delete.confirm", comment: "Delete confirmation"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { meeting in
            Button(NSLocalizedString("common.delete", comment: "Delete"), role: .destructive) {
                MeetingsViewModel(modelContext: modelContext).delete(meeting)
                pendingDelete = nil
            }
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {
                pendingDelete = nil
            }
        } message: { meeting in
            Text(meeting.title)
        }
    }
}

/// One row in the meetings list.
private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if meeting.summary != nil {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                        .accessibilityLabel(Text(
                            NSLocalizedString("meeting.has_summary", comment: "Has summary")
                        ))
                }
            }
            HStack(spacing: 8) {
                Text(meeting.createdAt.meetingDisplay)
                if meeting.totalDuration > 0 {
                    Text("·")
                    Text(meeting.totalDuration.clockDisplay)
                }
                Spacer()
                StatusBadge(status: meeting.aggregateStatus)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Small colored pill showing a transcription status.
struct StatusBadge: View {
    let status: TranscriptionStatus

    var body: some View {
        if let label = label {
            Text(label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
    }

    private var label: String? {
        switch status {
        case .none: return nil
        case .inProgress: return NSLocalizedString("status.in_progress", comment: "")
        case .done: return NSLocalizedString("status.done", comment: "")
        case .failed: return NSLocalizedString("status.failed", comment: "")
        }
    }

    private var color: Color {
        switch status {
        case .none: return .secondary
        case .inProgress: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}
