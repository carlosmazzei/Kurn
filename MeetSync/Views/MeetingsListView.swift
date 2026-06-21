//
//  MeetingsListView.swift
//  MeetSync
//
//  Lists all meetings (most recent first) with a search field, date filters,
//  status/summary indicators, delete (confirmed), and entry points for creating
//  a meeting or opening settings.
//

import SwiftData
import SwiftUI

/// Date-range filter for the meetings list.
private enum MeetingDateFilter: String, CaseIterable, Identifiable {
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

struct MeetingsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]

    @State private var showingNewMeeting = false
    @State private var showingSettings = false
    @State private var pendingDelete: Meeting?
    @State private var searchText = ""
    @State private var filter: MeetingDateFilter = .all

    private var filtered: [Meeting] {
        meetings.filter { meeting in
            guard filter.matches(meeting.createdAt) else { return false }
            guard !searchText.isEmpty else { return true }
            let needle = searchText.lowercased()
            return meeting.title.lowercased().contains(needle)
                || preview(for: meeting).lowercased().contains(needle)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchField
                filterChips
                if filtered.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { meeting in
                            NavigationLink(value: meeting) {
                                MeetingCard(meeting: meeting, preview: preview(for: meeting))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDelete = meeting
                                } label: {
                                    Label(NSLocalizedString("common.delete", comment: "Delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("MeetSync")
        .navigationDestination(for: Meeting.self) { meeting in
            MeetingDetailView(meeting: meeting)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewMeeting = true } label: {
                    Label(NSLocalizedString("meetings.new", comment: "New Meeting"), systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingNewMeeting) {
            NavigationStack { MeetingFormView() }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
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

    // MARK: - Subviews

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textTertiary)
            TextField(
                NSLocalizedString("meetings.search", comment: "Search recordings…"),
                text: $searchText
            )
            .textInputAutocapitalization(.never)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(MeetingDateFilter.allCases) { option in
                FilterChip(title: option.title, isSelected: filter == option) {
                    filter = option
                }
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.largeTitle)
                .foregroundStyle(Theme.textTertiary)
            Text(NSLocalizedString("meetings.empty.title", comment: "No meetings"))
                .font(.headline)
            Text(NSLocalizedString("meetings.empty.subtitle", comment: ""))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func preview(for meeting: Meeting) -> String {
        if let segment = meeting.recordings
            .sorted(by: { $0.recordedAt < $1.recordedAt })
            .compactMap({ $0.transcript?.segments.first?.text })
            .first {
            return segment
        }
        return meeting.notes
    }
}

/// One card in the meetings list.
private struct MeetingCard: View {
    let meeting: Meeting
    let preview: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(meeting.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if meeting.summary != nil {
                    Image(systemName: "sparkles").foregroundStyle(Theme.info)
                }
                StatusBadge(status: meeting.aggregateStatus)
            }
            HStack(spacing: 6) {
                Text(meeting.createdAt.meetingDisplay)
                if meeting.totalDuration > 0 {
                    Text("·")
                    Text(meeting.totalDuration.clockDisplay)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)

            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .meetsyncCard()
    }
}
