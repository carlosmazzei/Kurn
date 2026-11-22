//
//  MeetingsListView.swift
//  Kurn
//
//  Lists all meetings with a search field (full-text across titles, notes and
//  transcripts), a library selector that opens a sidebar drawer (built-in
//  buckets All / Inbox / Favorites / Archive plus user folders), date filters,
//  a configurable sort menu, status/summary chips, leading swipe for
//  favorite/archive, trailing swipe for delete, a long-press context menu
//  (favorite / archive / move to folder / rename / share / select / delete),
//  a selection mode for deleting or exporting several meetings at once (see
//  `MeetingsListSelectionMode.swift`), and entry points for creating a meeting
//  or opening settings.
//

import KurnCore
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

    // Several of the members below are deliberately non-private: the toolbar
    // content lives in `MeetingsListToolbar.swift`, and a `private` member is
    // not visible to an extension declared in another file.
    @Environment(\.modelContext) var modelContext
    @Environment(AppSettings.self) var settings
    @Environment(RecordingSessionController.self) var session
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @Query private var folders: [Folder]
    @Query(sort: \SmartFolder.name) private var smartFolders: [SmartFolder]

    @State var showingSettings = false
    @State private var pendingDelete: Meeting?
    /// Pushed meeting detail (item-based so cards have no disclosure chevron).
    @State private var selectedMeeting: Meeting?
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
    @State var showingAsk = false
    /// Pushes the generated-document library from the shared bottom toolbar.
    @State var showingDocuments = false
    private let semanticSearchService = SemanticSearchService()
    @State var filter = MeetingFilter()
    /// The quick chip layered over `filter` and `selection` (All / Favorites /
    /// No summary); app-local, never persisted.
    @State var quickFilter: MeetingQuickFilter = .all
    /// Owned by `ContentView`, not this view — on iPad-regular width the same
    /// binding also drives `FolderSidebarView`'s persistent `NavigationSplitView`
    /// sidebar column, so a folder tap
    /// there updates this list without a sheet round-trip. On compact width
    /// `ContentView` still owns the state, just with no sidebar column reading it.
    @Binding var selection: LibrarySelection
    /// Meetings the Knowledge sheet opens on, for deterministic UI-test
    /// captures; empty in the app, where the person chooses them.
    var initialKnowledgeSourceIDs: Set<UUID> = []
    /// With Knowledge on, the library's Knowledge reader (a sheet) and the
    /// meetings it reads. The selection lives here so it outlasts the sheet.
    @State var showingKnowledge = false
    @State var knowledgeSourceIDs: Set<UUID> = []
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @State var showingSidebar = false
    @State var showingFilterBar = false
    /// Set when the context-menu "Move to folder…" action is invoked; presents
    /// `FolderPickerView` against the chosen meeting.
    @State private var movingMeeting: Meeting?
    /// Set when the context-menu "Edit tags" action is invoked; presents
    /// `TagPickerView` against the chosen meeting.
    @State private var taggingMeeting: Meeting?
    /// Set when a favorite/archive/create/delete persistence op fails, so the
    /// failure surfaces instead of being dropped silently.
    @State var saveError: AppError?
    /// Selection mode: which meetings are picked for a bulk delete or export.
    @State var listSelection = MeetingListSelection()
    @State var showingBulkExport = false
    @State var pendingBulkDelete = false
    /// Selection-mode bulk actions: move every selected meeting to a folder,
    /// or toggle tags on all of them at once.
    @State var bulkMoving = false
    @State var bulkTagging = false

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

    /// Title shown in the toolbar's library button reflecting `selection`.
    var selectionTitle: String {
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

    var selectionSystemImage: String {
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
                && quickFilter.contains(meeting)
                && filter.matches(meeting)
        }
    }

    var filtered: [Meeting] {
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

    // Authentication is not this view's concern any more. The gate used to be a
    // branch here — `if isLocked { LockedRecordingsView } else { … }` — which
    // destroyed every sheet attached to the unlocked branch on each background
    // transition, so each new sheet became a choice between protecting content
    // and preserving the user's work. The cover now lives in a window above the
    // whole app (`securityCover(…)` in `KurnApp`), so presentations below can be
    // attached wherever reads best.
    /// Date sorts group `filtered` into one section per calendar day; title
    /// and duration sorts keep one flat section whose rows carry the date.
    private var usesDayGrouping: Bool {
        settings.meetingsSortOrder == .dateNewest || settings.meetingsSortOrder == .dateOldest
    }

    private var daySections: [DaySection<Meeting>] {
        DaySections.group(filtered, date: { $0.createdAt })
    }

    var body: some View {
        List {
            // No chips on the true first-use empty state; they stay whenever
            // meetings exist but a filter/search/chip hides them all.
            if !meetings.isEmpty {
                quickChips
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            if filtered.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if usesDayGrouping {
                ForEach(daySections, id: \.day) { section in
                    Section {
                        ForEach(section.items) { meeting in
                            meetingRow(meeting, showsDate: false)
                        }
                    } header: {
                        dayHeader(for: section.day)
                    }
                }
            } else {
                Section {
                    ForEach(filtered) { meeting in
                        meetingRow(meeting, showsDate: true)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(listTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(NSLocalizedString("meetings.search", comment: "Search recordings…"))
        )
        .textInputAutocapitalization(.never)
        .toolbar { listToolbar }
        .hostsRecordingMiniBar()
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
        }
        .navigationDestination(item: $selectedMeeting) { meeting in
            MeetingDetailView(meeting: meeting)
        }
        .navigationDestination(isPresented: $showingDocuments) {
            DocumentsListView()
        }
        .sheet(item: $editingMeeting) { meeting in
            NavigationStack { MeetingFormView(meeting: meeting) }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.urls)
        }
        .sheet(isPresented: $showingBulkExport) {
            MeetingBulkExportView(meetings: selectedMeetings) { urls in
                listSelection.end()
                shareItem = ShareItem(urls: urls)
            }
        }
        .sheet(item: $movingMeeting) { meeting in
            FolderPickerView(meeting: meeting)
        }
        .sheet(item: $taggingMeeting) { meeting in
            TagPickerView(meeting: meeting)
        }
        .sheet(isPresented: $bulkMoving) {
            FolderPickerView(meetings: selectedMeetings) { listSelection.end() }
        }
        .sheet(isPresented: $bulkTagging) {
            TagPickerView(meetings: selectedMeetings) { listSelection.end() }
        }
        .sheet(isPresented: $showingSidebar) {
            FolderSidebarView(selection: $selection, filter: $filter)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingFilterBar) {
            FilterBarView(filter: $filter, matchCount: matchCount(for:))
        }
        .sheet(isPresented: $showingAsk) {
            NavigationStack {
                MeetingChatView(meeting: nil)
                .navigationTitle(NSLocalizedString("chat.ask.title", comment: "Ask across meetings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(NSLocalizedString("common.done", comment: "Done")) { showingAsk = false }
                    }
                }
            }
            .hostsRecordingMiniBarInSheet()
        }
        .sheet(isPresented: $showingKnowledge) {
            KnowledgeLibraryDestination(meetingIDs: $knowledgeSourceIDs).hostsRecordingMiniBarInSheet()
        }
        .task(id: initialKnowledgeSourceIDs) {
            guard !initialKnowledgeSourceIDs.isEmpty else { return }
            knowledgeSourceIDs = initialKnowledgeSourceIDs
            showingKnowledge = true
        }
        .onChange(of: settings.knowledgeEnabled) { _, enabled in
            if !enabled { knowledgeSourceIDs = [] }
        }
        .task(id: searchText) { await runSemanticSearch() }
        .kurnDialog(
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.destructive,
            title: String(
                format: NSLocalizedString("meetings.delete.confirm_titled", comment: "Delete confirmation"),
                pendingDelete?.title ?? ""
            ),
            message: NSLocalizedString("meetings.delete.message", comment: "What a meeting delete erases"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                guard let meeting = pendingDelete else { return }
                do throws(AppError) {
                    try MeetingLibrary(context: modelContext).deleteMeeting(meeting)
                } catch {
                    saveError = error
                }
                pendingDelete = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: {
                pendingDelete = nil
            }
        )
        .bulkDeleteDialog(
            isPresented: $pendingBulkDelete,
            count: selectedMeetings.count,
            onConfirm: deleteSelectedMeetings
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

    /// The quick-filter chips that replaced the old date row: one line of
    /// All / Favorites / No summary, ink when selected.
    var quickChips: some View {
        HStack(spacing: 8) {
            ForEach(MeetingQuickFilter.allCases) { option in
                FilterChip(
                    title: option.title,
                    isSelected: quickFilter == option,
                    tint: quickFilter == option ? Theme.ink : .primary
                ) {
                    quickFilter = option
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Meetings counted by the Filters sheet's "Show N" button: everything
    /// the bucket and quick chip allow that a candidate `MeetingFilter`
    /// would keep. Search text deliberately plays no part — it is not part
    /// of what the sheet edits.
    func matchCount(for candidate: MeetingFilter) -> Int {
        meetings.count { meeting in
            selection.contains(meeting, smartFolderFilter: smartFolderFilter)
                && quickFilter.contains(meeting)
                && candidate.matches(meeting)
        }
    }

    /// Day-grouped lists omit the date from each row (the header carries it);
    /// flat sorts pass `showsDate` so the metadata line leads with it.
    func meetingRow(_ meeting: Meeting, showsDate: Bool) -> some View {
        Button {
            if !listSelection.handleTap(on: meeting.id) { selectedMeeting = meeting }
        } label: {
            selectableCard(for: meeting, showsDate: showsDate)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MeetingCard(meeting: meeting, showsDate: showsDate).accessibilitySummary)
        .accessibilityAddTraits(listSelection.isSelected(meeting.id) ? .isSelected : [])
        .accessibilityIdentifier("meetingCard")
        .listRowBackground(Theme.surface)
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
        .contextMenu { meetingContextMenu(meeting) }
    }

    /// Long-press menu: favourite, rename, tags, move, share, archive, delete.
    /// Select is deliberately absent — it lives in the ⋯ toolbar menu.
    @ViewBuilder
    private func meetingContextMenu(_ meeting: Meeting) -> some View {
        Button { toggleFavorite(meeting) } label: {
            Label(
                meeting.isFavorite
                    ? NSLocalizedString("meetings.unfavorite", comment: "Unfavorite")
                    : NSLocalizedString("meetings.favorite", comment: "Favorite"),
                systemImage: meeting.isFavorite ? "star.slash" : "star"
            )
        }
        Button { editingMeeting = meeting } label: {
            Label(
                NSLocalizedString("meetings.rename", comment: "Rename"),
                systemImage: "pencil"
            )
        }
        Button { taggingMeeting = meeting } label: {
            Label(
                NSLocalizedString("meetings.tag.edit", comment: "Edit tags"),
                systemImage: "tag"
            )
        }
        Button { movingMeeting = meeting } label: {
            Label(
                NSLocalizedString("folder.move_to", comment: "Move to folder"),
                systemImage: "folder"
            )
        }
        Button { share(meeting) } label: {
            Label(
                NSLocalizedString("detail.share", comment: "Share"),
                systemImage: "square.and.arrow.up"
            )
        }
        Divider()
        Button { toggleArchive(meeting) } label: {
            Label(
                meeting.isArchived
                    ? NSLocalizedString("meetings.unarchive", comment: "Unarchive")
                    : NSLocalizedString("meetings.archive", comment: "Archive"),
                systemImage: meeting.isArchived ? "tray.and.arrow.up" : "archivebox"
            )
        }
        Button(role: .destructive) { pendingDelete = meeting } label: {
            Label(
                NSLocalizedString("common.delete", comment: "Delete"),
                systemImage: "trash"
            )
        }
    }

    /// "Today" / "Yesterday" / the weekday date, bold, with the full date in
    /// secondary underneath for the two relative days.
    @ViewBuilder
    private func dayHeader(for day: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let isYesterday = calendar.isDateInYesterday(day)
        VStack(alignment: .leading, spacing: 2) {
            Text(
                isToday
                    ? NSLocalizedString("meetings.day.today", comment: "Today")
                    : isYesterday
                        ? NSLocalizedString("meetings.day.yesterday", comment: "Yesterday")
                        : dayDateText(day)
            )
            .font(Theme.title3)
            // insetGrouped headers default to grey uppercase; the prototype
            // wants bold ink + a grey date line.
            .foregroundStyle(Theme.textPrimary)
            if isToday || isYesterday {
                Text(dayDateText(day))
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
    }

    /// "Thursday, November 20" — with the year appended only when the day is
    /// not in the current year.
    private func dayDateText(_ day: Date) -> String {
        if Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    /// (a) Nothing at all → invite the first recording; (b) meetings exist but
    /// a chip, the filters or the search hide every one.
    @ViewBuilder
    private var emptyState: some View {
        if meetings.isEmpty {
            ContentUnavailableView {
                Label(
                    NSLocalizedString("meetings.empty.title", comment: "No meetings"),
                    systemImage: "waveform"
                )
            } description: {
                Text(NSLocalizedString("meetings.empty.subtitle", comment: ""))
            } actions: {
                // Shares `RecordingActionButton`'s create-and-begin path but
                // not its chrome: glassProminent stretches to fill the
                // actions column, so this one is capped to a fixed height.
                Button {
                    saveError = RecordingActionButton.createAndBeginRecording(
                        context: modelContext, settings: settings, session: session
                    )
                } label: {
                    Text(NSLocalizedString("meetings.empty.record_first", comment: "Record your first meeting"))
                        .frame(height: 44)
                        .padding(.horizontal, 24)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.record)
                .fixedSize()
            }
        } else if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView(
                NSLocalizedString("meetings.empty.filtered.title", comment: "No meetings match"),
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text(NSLocalizedString("meetings.empty.filtered.subtitle", comment: ""))
            )
        }
    }
}
