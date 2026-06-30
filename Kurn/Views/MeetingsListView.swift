//
//  MeetingsListView.swift
//  Kurn
//
//  Lists all meetings with a search field (full-text across titles, notes and
//  transcripts), library bucket (All / Favorites / Archive) + date filters, a
//  configurable sort menu, status/summary chips, leading swipe for
//  favorite/archive, trailing swipe for delete, a long-press context menu
//  (favorite / archive / rename / share / delete), and entry points for
//  creating a meeting or opening settings.
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
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingAccessGate.self) private var accessGate
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]

    @State private var showingSettings = false
    @State private var pendingDelete: Meeting?
    /// Pushed meeting detail (item-based so cards have no disclosure chevron).
    @State private var selectedMeeting: Meeting?
    /// Set when the center record button creates a meeting to record into.
    @State private var recordMeeting: Meeting?
    /// Set by the context-menu "Rename" action; presents `MeetingFormView`.
    @State private var editingMeeting: Meeting?
    /// Set by the context-menu "Share" action; presents `ActivityView`.
    @State private var shareItem: ShareItem?
    @State private var searchText = ""
    @State private var filter: MeetingDateFilter = .all
    @State private var bucket: MeetingsLibraryBucket = .all

    private var isLocked: Bool {
        settings.requireAuthForRecordings && !accessGate.isUnlocked
    }

    private var filtered: [Meeting] {
        let searched = meetings.filter { meeting in
            guard bucket.contains(meeting) else { return false }
            guard filter.matches(meeting.createdAt) else { return false }
            return meeting.matches(search: searchText)
        }
        return settings.meetingsSortOrder.apply(to: searched)
    }

    private func toggleFavorite(_ meeting: Meeting) {
        meeting.isFavorite.toggle()
        try? modelContext.save()
    }

    private func toggleArchive(_ meeting: Meeting) {
        meeting.archivedAt = meeting.isArchived ? nil : Date()
        try? modelContext.save()
    }

    var body: some View {
        if isLocked {
            LockedRecordingsView(gate: accessGate)
                .background(Theme.background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .task { await accessGate.authenticate() }
        } else {
            unlockedBody
        }
    }

    private var unlockedBody: some View {
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
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { toggleFavorite(meeting) } label: {
                            Label(
                                meeting.isFavorite
                                    ? NSLocalizedString("meetings.unfavorite", comment: "Unfavorite")
                                    : NSLocalizedString("meetings.favorite", comment: "Favorite"),
                                systemImage: meeting.isFavorite ? "star.slash" : "star"
                            )
                        }
                        .tint(Theme.warning)
                        Button { toggleArchive(meeting) } label: {
                            Label(
                                meeting.isArchived
                                    ? NSLocalizedString("meetings.unarchive", comment: "Unarchive")
                                    : NSLocalizedString("meetings.archive", comment: "Archive"),
                                systemImage: meeting.isArchived ? "tray.and.arrow.up" : "archivebox"
                            )
                        }
                        .tint(Theme.info)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = meeting } label: {
                            Label(NSLocalizedString("common.delete", comment: "Delete"), systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            toggleFavorite(meeting)
                        } label: {
                            Label(
                                meeting.isFavorite
                                    ? NSLocalizedString("meetings.unfavorite", comment: "Unfavorite")
                                    : NSLocalizedString("meetings.favorite", comment: "Favorite"),
                                systemImage: meeting.isFavorite ? "star.slash" : "star"
                            )
                        }
                        Button {
                            toggleArchive(meeting)
                        } label: {
                            Label(
                                meeting.isArchived
                                    ? NSLocalizedString("meetings.unarchive", comment: "Unarchive")
                                    : NSLocalizedString("meetings.archive", comment: "Archive"),
                                systemImage: meeting.isArchived ? "tray.and.arrow.up" : "archivebox"
                            )
                        }
                        Divider()
                        Button {
                            editingMeeting = meeting
                        } label: {
                            Label(
                                NSLocalizedString("meetings.rename", comment: "Rename"),
                                systemImage: "pencil"
                            )
                        }
                        Button {
                            share(meeting)
                        } label: {
                            Label(
                                NSLocalizedString("detail.share", comment: "Share"),
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        Divider()
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
        .sheet(item: $editingMeeting) { meeting in
            NavigationStack { MeetingFormView(meeting: meeting) }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .kurnDialog(
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("meetings.delete.confirm", comment: "Delete confirmation"),
            message: pendingDelete?.title ?? "",
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                guard let meeting = pendingDelete else { return }
                MeetingsViewModel(modelContext: modelContext).delete(meeting)
                pendingDelete = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: {
                pendingDelete = nil
            }
        )
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
            bucketMenu
            ForEach(MeetingDateFilter.allCases) { option in
                FilterChip(title: option.title, isSelected: filter == option) {
                    filter = option
                }
            }
            Spacer()
            sortMenu
        }
    }

    private var bucketMenu: some View {
        Menu {
            Picker(
                NSLocalizedString("meetings.bucket", comment: "Library bucket"),
                selection: $bucket
            ) {
                ForEach(MeetingsLibraryBucket.allCases) { option in
                    Label(option.displayName, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Image(systemName: bucket.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(bucket == .all ? Theme.textSecondary : Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.fill, in: Circle())
        }
        .accessibilityLabel(NSLocalizedString("meetings.bucket", comment: "Library bucket"))
        .accessibilityValue(bucket.displayName)
    }

    private var sortMenu: some View {
        Menu {
            Picker(
                NSLocalizedString("meetings.sort", comment: "Sort"),
                selection: Binding(
                    get: { settings.meetingsSortOrder },
                    set: { settings.meetingsSortOrder = $0 }
                )
            ) {
                ForEach(MeetingsSortOrder.allCases) { order in
                    Label(order.displayName, systemImage: order.systemImage).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Theme.fill, in: Circle())
        }
        .accessibilityLabel(NSLocalizedString("meetings.sort", comment: "Sort"))
    }

    private func share(_ meeting: Meeting) {
        guard let url = try? MeetingExport.temporaryFile(for: meeting) else { return }
        shareItem = ShareItem(url: url)
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

/// Full-screen overlay shown in place of the meetings list while the gate is
/// locked. Triggers authentication automatically when it appears and offers a
/// retry button when the user cancels the prompt or biometrics fail.
private struct LockedRecordingsView: View {
    let gate: RecordingAccessGate

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.textSecondary)
            Text(NSLocalizedString("recordings.locked_title", comment: "Recordings Locked"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(NSLocalizedString("recordings.locked_subtitle", comment: "Authenticate to view"))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let message = gate.lastError?.errorDescription {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await gate.authenticate() }
            } label: {
                Text(NSLocalizedString("recordings.unlock_button", comment: "Unlock"))
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One card in the meetings list.
private struct MeetingCard: View {
    let meeting: Meeting
    let preview: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if meeting.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.system(size: 13))
                        .accessibilityLabel(NSLocalizedString("meetings.favorite", comment: "Favorite"))
                }
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

            metaChips

            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .kurnCard()
    }

    /// Optional row of scannable chips: # speakers, # recordings, summary
    /// template. Each chip only appears when it adds information (≥2 speakers,
    /// >1 recording, template named).
    @ViewBuilder
    private var metaChips: some View {
        let speakerCount = meeting.speakers.count
        let recordingCount = meeting.recordings.count
        let templateName = meeting.summary?.templateName ?? ""
        if speakerCount >= 2 || recordingCount > 1 || !templateName.isEmpty {
            HStack(spacing: 6) {
                if speakerCount >= 2 {
                    metaChip(systemImage: "person.2.fill", text: "\(speakerCount)")
                }
                if recordingCount > 1 {
                    metaChip(systemImage: "waveform", text: "\(recordingCount)")
                }
                if !templateName.isEmpty {
                    metaChip(systemImage: "doc.text", text: templateName)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func metaChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.fill, in: Capsule())
    }
}
