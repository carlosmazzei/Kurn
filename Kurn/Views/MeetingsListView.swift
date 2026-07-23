//
//  MeetingsListView.swift
//  Kurn
//
//  Lists all meetings with a search field (full-text across titles, notes and
//  transcripts), a library selector that opens a sidebar drawer (built-in
//  buckets All / Inbox / Favorites / Archive plus user folders), date filters,
//  a configurable sort menu, status/summary chips, leading swipe for
//  favorite/archive, trailing swipe for delete, a long-press context menu
//  (favorite / archive / move to folder / rename / share / delete), and entry
//  points for creating a meeting or opening settings.
//

import SwiftData
import SwiftUI

struct MeetingsListView: View {
    /// Max number of semantic-only meetings appended to the substring matches.
    /// A hard cap is what keeps search feeling like a filter: without it, the
    /// permissive similarity floor of on-device embeddings floods the list.
    private static let semanticResultLimit = 5
    /// Minimum cosine similarity for a chunk to count. `NLContextualEmbedding`
    /// mean-pooled vectors aren't zero-centered, so this floor is well above 0.
    private static let semanticMinScore: Float = 0.35
    /// Keep only meetings within this margin of the top match, so a query with
    /// one clearly-relevant meeting doesn't drag in loosely-related ones.
    private static let semanticScoreMargin: Float = 0.06

    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingAccessGate.self) private var accessGate
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @Query private var folders: [Folder]
    @Query(sort: \SmartFolder.name) private var smartFolders: [SmartFolder]

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
    /// Best semantic hit per meeting for the current query, filled by a debounced
    /// task. Empty when the query is empty or the feature is off, so the list
    /// falls back to plain substring matching.
    @State private var semanticHits: [SemanticSearchService.Hit] = []
    /// Presents the library-wide "Ask" chat sheet.
    @State private var showingAsk = false
    private let semanticSearchService = SemanticSearchService()
    @State private var filter = MeetingFilter()
    @State private var selection: LibrarySelection = .allMeetings
    @State private var showingSidebar = false
    @State private var showingFilterBar = false
    /// Set when the context-menu "Move to folder…" action is invoked; presents
    /// `FolderPickerView` against the chosen meeting.
    @State private var movingMeeting: Meeting?
    /// Set when the context-menu "Edit tags" action is invoked; presents
    /// `TagPickerView` against the chosen meeting.
    @State private var taggingMeeting: Meeting?
    /// Set when a favorite/archive/create/delete persistence op fails, so the
    /// failure surfaces instead of being dropped silently.
    @State private var saveError: AppError?

    private var isLocked: Bool {
        settings.requireAuthForRecordings && !accessGate.isUnlocked
    }

    /// The currently-selected folder, looked up through the dedicated `@Query`
    /// so renames and deletions reflect immediately in the chip title.
    private var selectedFolder: Folder? {
        guard case .folder(let id) = selection else { return nil }
        return folders.first(where: { $0.persistentModelID == id })
    }

    /// The currently-selected smart folder, if any.
    private var selectedSmartFolder: SmartFolder? {
        guard case .smartFolder(let id) = selection else { return nil }
        return smartFolders.first(where: { $0.id == id })
    }

    /// Title shown in the chip row reflecting the current `selection`.
    private var selectionTitle: String {
        switch selection {
        case .bucket(let bucket): return bucket.displayName
        case .folder:
            return selectedFolder?.name
                ?? NSLocalizedString("folder.deleted", comment: "Deleted folder fallback")
        case .smartFolder:
            return selectedSmartFolder?.name
                ?? NSLocalizedString("folder.deleted", comment: "Deleted smart folder fallback")
        }
    }

    private var selectionSystemImage: String {
        switch selection {
        case .bucket(let bucket): return bucket.systemImage
        case .folder: return selectedFolder?.iconName ?? "folder"
        case .smartFolder: return selectedSmartFolder?.iconName ?? "sparkles.square.fill.on.square"
        }
    }

    private var smartFolderFilter: MeetingFilter? {
        selectedSmartFolder?.filter
    }

    /// Meetings passing the current bucket/folder + structured filter, before any
    /// text search. Shared by substring and semantic search.
    private var scoped: [Meeting] {
        meetings.filter { meeting in
            selection.contains(meeting, smartFolderFilter: smartFolderFilter)
                && filter.matches(meeting)
        }
    }

    private var filtered: [Meeting] {
        let base = scoped
        guard !searchText.isEmpty else { return settings.meetingsSortOrder.apply(to: base) }

        let substring = base.filter { $0.matches(search: searchText) }
        // Augment with semantically-relevant meetings the substring pass missed,
        // in descending relevance. When the feature is off or nothing was
        // embedded yet, `semanticHits` is empty and this is a no-op.
        guard settings.semanticSearchEnabled, !semanticHits.isEmpty else {
            return settings.meetingsSortOrder.apply(to: substring)
        }
        let substringIDs = Set(substring.map(\.id))
        let byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let semanticOnly = semanticHits.compactMap { hit -> Meeting? in
            guard !substringIDs.contains(hit.meetingID) else { return nil }
            return byID[hit.meetingID]
        }
        return settings.meetingsSortOrder.apply(to: substring) + semanticOnly
    }

    /// Debounced semantic search: embed the query once and keep the best hit per
    /// meeting. Runs off the substring path so typing stays instant.
    private func runSemanticSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.semanticSearchEnabled, !query.isEmpty else {
            semanticHits = []
            return
        }
        // Debounce so we don't embed on every keystroke.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        let candidates = scoped.flatMap { $0.semanticChunks.map(\.searchCandidate) }
        guard !candidates.isEmpty else {
            semanticHits = []
            return
        }
        do {
            let hits = try await semanticSearchService.search(
                query: query, in: candidates, limit: 30, minScore: Self.semanticMinScore
            )
            guard !Task.isCancelled else { return }
            semanticHits = Self.boundedHits(SemanticSearchService.bestPerMeeting(hits))
        } catch {
            semanticHits = []
        }
    }

    /// Keep only meetings close to the top match, capped to a few, so semantic
    /// results augment the substring filter instead of flooding it.
    private static func boundedHits(_ hits: [SemanticSearchService.Hit]) -> [SemanticSearchService.Hit] {
        guard let top = hits.first?.score else { return [] }
        let floor = top - semanticScoreMargin
        return Array(hits.filter { $0.score >= floor }.prefix(semanticResultLimit))
    }

    private func toggleFavorite(_ meeting: Meeting) {
        meeting.isFavorite.toggle()
        saveError = modelContext.saveOrError()
    }

    private func toggleArchive(_ meeting: Meeting) {
        meeting.archivedAt = meeting.isArchived ? nil : Date()
        saveError = modelContext.saveOrError()
    }

    var body: some View {
        Group {
            if isLocked {
                LockedRecordingsView(gate: accessGate, showingSettings: $showingSettings)
                    .background(Theme.background.ignoresSafeArea())
                    .toolbar(.hidden, for: .navigationBar)
                    .task { await accessGate.authenticate() }
            } else {
                unlockedBody
            }
        }
        // The recorder sheet is attached OUTSIDE the locked/unlocked branch on
        // purpose: the gate locks on every background transition, and a sheet
        // attached to `unlockedBody` would be torn down with it — destroying
        // the live RecorderViewModel mid-recording (audio orphaned unfinalized,
        // Live Activity stuck) and then auto-presenting a fresh recorder after
        // re-auth because `recordMeeting` survives the swap. Out here the
        // running recorder stays presented above the locked placeholder; the
        // meeting list below still requires authentication.
        .sheet(item: $recordMeeting) { meeting in
            NavigationStack { RecorderView(meeting: meeting) }
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
                    .accessibilityIdentifier("meetingCard")
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
                        Button {
                            movingMeeting = meeting
                        } label: {
                            Label(
                                NSLocalizedString("folder.move_to", comment: "Move to folder"),
                                systemImage: "folder"
                            )
                        }
                        Button {
                            taggingMeeting = meeting
                        } label: {
                            Label(
                                NSLocalizedString("meetings.tag.edit", comment: "Edit tags"),
                                systemImage: "tag"
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
        .sheet(item: $editingMeeting) { meeting in
            NavigationStack { MeetingFormView(meeting: meeting) }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.urls)
        }
        .sheet(item: $movingMeeting) { meeting in
            FolderPickerView(meeting: meeting)
        }
        .sheet(item: $taggingMeeting) { meeting in
            TagPickerView(meeting: meeting)
        }
        .sheet(isPresented: $showingSidebar) {
            FolderSidebarView(selection: $selection)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingFilterBar) {
            FilterBarView(filter: $filter)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(isPresented: $showingAsk) {
            NavigationStack {
                MeetingChatView(meeting: nil, onJump: { hit in
                    showingAsk = false
                    if let meeting = meetings.first(where: { $0.id == hit.meetingID }) {
                        selectedMeeting = meeting
                    }
                })
                .navigationTitle(NSLocalizedString("chat.ask.title", comment: "Ask across meetings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(NSLocalizedString("common.done", comment: "Done")) { showingAsk = false }
                    }
                }
            }
        }
        .task(id: searchText) { await runSemanticSearch() }
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
                let viewModel = MeetingsViewModel(modelContext: modelContext)
                viewModel.delete(meeting)
                saveError = viewModel.error
                pendingDelete = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: {
                pendingDelete = nil
            }
        )
        .errorAlert($saveError)
    }

    private func share(_ meeting: Meeting) {
        guard let url = try? MeetingExport.temporaryFile(for: meeting, summary: meeting.latestSummary) else { return }
        shareItem = ShareItem(urls: [url])
    }
}

// MARK: - Subviews (kept out of the struct body to stay under the linter limit)

extension MeetingsListView {

    var bottomBar: some View {
        HStack(alignment: .center) {
            bottomTab(icon: "square.grid.2x2.fill",
                      label: NSLocalizedString("tab.meetings", comment: "Meetings"),
                      active: true) {}
                .accessibilityIdentifier("nav.meetings")
            Spacer()
            bottomTab(icon: "gearshape.fill",
                      label: NSLocalizedString("settings.title", comment: "Settings"),
                      active: false) { showingSettings = true }
                .accessibilityIdentifier("nav.settings")
        }
        .padding(.horizontal, 56)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(alignment: .top) { Divider().overlay(Theme.separator) }
        .background(.bar)
        .overlay(alignment: .top) { recordButton.offset(y: -26) }
    }

    func bottomTab(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
        }
        .buttonStyle(.plain)
    }

    var recordButton: some View {
        Button {
            let viewModel = MeetingsViewModel(modelContext: modelContext)
            let meeting = viewModel.createMeeting(title: "")
            saveError = viewModel.error
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

    var searchField: some View {
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

    var filterChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sidebarTrigger
                filterMenu
                Spacer()
                if settings.semanticSearchEnabled {
                    askButton
                }
                sortMenu
            }
            HStack(spacing: 8) {
                ForEach(MeetingDateFilter.allCases) { option in
                    FilterChip(
                        title: option.title,
                        isSelected: filter.dateRange == option,
                        tint: filter.dateRange == option ? Theme.accent : .primary
                    ) {
                        filter.dateRange = option
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    var askButton: some View {
        Button { showingAsk = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12, weight: .semibold))
                Text(NSLocalizedString("meetings.ask", comment: "Ask"))
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.accent.opacity(0.12), in: Capsule())
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("meetings.ask")
    }

    var filterMenu: some View {
        Button { showingFilterBar = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12, weight: .semibold))
                if filter.isActive {
                    Text("\(filter.activeCount)")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(filter.isActive ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("filter.title", comment: "Filters"))
    }

    /// Button on the chip row that opens `FolderSidebarView`. The label
    /// mirrors the active selection (built-in bucket icon or folder icon +
    /// name) so the user always sees what they're looking at.
    var sidebarTrigger: some View {
        let isDefault = selection == .allMeetings
        return Button { showingSidebar = true } label: {
            HStack(spacing: 6) {
                Image(systemName: selectionSystemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(selectionTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(isDefault ? Theme.textSecondary : Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.fill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("meetings.bucket", comment: "Library"))
        .accessibilityValue(selectionTitle)
    }

    var sortMenu: some View {
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

    var emptyState: some View {
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

    func preview(for meeting: Meeting) -> String {
        meeting.aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
