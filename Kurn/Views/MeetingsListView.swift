//
//  MeetingsListView.swift
//  Kurn
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

    @State private var showingSettings = false
    @State private var pendingDelete: Meeting?
    /// Pushed meeting detail (item-based so cards have no disclosure chevron).
    @State private var selectedMeeting: Meeting?
    /// Set when the center record button creates a meeting to record into.
    @State private var recordMeeting: Meeting?
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
        ZStack(alignment: .bottom) {
        List {
            VStack(alignment: .leading, spacing: 16) {
                Text("Kurn")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                searchField
                filterChips
            }
            .clearListRow(insets: EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))

            if filtered.isEmpty {
                emptyState.clearListRow()
            } else {
                ForEach(filtered) { meeting in
                    Button { selectedMeeting = meeting } label: {
                        MeetingCard(meeting: meeting, preview: preview(for: meeting))
                    }
                    .buttonStyle(.plain)
                    .clearListRow(insets: EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = meeting } label: {
                            Label(NSLocalizedString("common.delete", comment: "Delete"), systemImage: "trash")
                        }
                    }
                }
            }

            // Spacer so the last card clears the floating bottom bar.
            Color.clear.frame(height: 84).clearListRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())

            bottomBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedMeeting) { meeting in
            MeetingDetailView(meeting: meeting)
        }
        .sheet(item: $recordMeeting) { meeting in
            NavigationStack { RecorderView(meeting: meeting) }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .alert(
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

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(alignment: .center) {
            bottomTab(icon: "square.grid.2x2.fill",
                      label: NSLocalizedString("tab.meetings", comment: "Meetings"),
                      active: true) {}
            Spacer()
            bottomTab(icon: "gearshape.fill",
                      label: NSLocalizedString("settings.title", comment: "Settings"),
                      active: false) { showingSettings = true }
        }
        .padding(.horizontal, 56)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(alignment: .top) { Divider().overlay(Theme.separator) }
        .background(.bar)
        .overlay(alignment: .top) { recordButton.offset(y: -26) }
    }

    private func bottomTab(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
        }
        .buttonStyle(.plain)
    }

    private var recordButton: some View {
        Button {
            let meeting = MeetingsViewModel(modelContext: modelContext).createMeeting(title: "")
            recordMeeting = meeting
        } label: {
            ZStack {
                Circle().fill(Theme.accent).frame(width: 56, height: 56)
                Circle().fill(.white).frame(width: 22, height: 22)
            }
            .shadow(color: Theme.accent.opacity(0.55), radius: 16, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(NSLocalizedString("meetings.new", comment: "New Meeting")))
    }

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
        .kurnCard()
    }
}
