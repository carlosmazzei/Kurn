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

    // Several of the members below are deliberately non-private: the toolbar
    // content lives in `MeetingsListToolbar.swift`, and a `private` member is
    // not visible to an extension declared in another file.
    @Environment(\.modelContext) var modelContext
    @Environment(AppSettings.self) var settings
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @Query private var folders: [Folder]
    @Query(sort: \SmartFolder.name) private var smartFolders: [SmartFolder]

    @State var showingSettings = false
    @State private var pendingDelete: Meeting?
    /// Pushed meeting detail (item-based so cards have no disclosure chevron).
    @State private var selectedMeeting: Meeting?
    /// Set when the toolbar's record button creates a meeting to record into.
    @State var recordMeeting: Meeting?
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
    @State var selection: LibrarySelection = .allMeetings
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

    // Authentication is not this view's concern any more. The gate used to be a
    // branch here — `if isLocked { LockedRecordingsView } else { … }` — which
    // destroyed every sheet attached to the unlocked branch on each background
    // transition, so each new sheet became a choice between protecting content
    // and preserving the user's work. The cover now lives in a window above the
    // whole app (`securityCover(…)` in `KurnApp`), so presentations below can be
    // attached wherever reads best.
    var body: some View {
        List {
            dateChips
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
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Kurn")
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(NSLocalizedString("meetings.search", comment: "Search recordings…"))
        )
        .textInputAutocapitalization(.never)
        .toolbar { listToolbar }
        .sheet(item: $recordMeeting) { meeting in
            NavigationStack { RecorderView(meeting: meeting) }
        }
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

    /// The one filter row that stays list content: the date range applies to
    /// browsing as well as searching, so it doesn't belong in `.searchScopes`,
    /// and four always-visible options would crowd the toolbar.
    var dateChips: some View {
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
