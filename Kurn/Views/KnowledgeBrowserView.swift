import Combine
import CoreData
import KurnCore
import SwiftUI
import UniformTypeIdentifiers

/// An explicitly scoped reader/search stack, shared by meeting entry and the
/// library's Knowledge sheet. Navigation carries IDs, never cached search text.
struct KnowledgeBrowserView: View {
    let meetingIDs: Set<UUID>
    let showsDone: Bool
    let onChooseSources: (() -> Void)?
    /// What the scope chip names, e.g. "This week"; empty hides the qualifier.
    var scopeLabel: String = ""
    var onOpenSettings: (() -> Void)?
    @Environment(KnowledgeCompilationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var model = KnowledgeBrowserViewModel()
    @State private var searchModel = KnowledgeSearchViewModel()
    @State private var searchQuery = ""
    @State private var searchRevision = 0
    @FocusState private var searchFocused: Bool
    @State private var path: [KnowledgeBrowserRoute] = []
    @State private var refresh = 0
    @State private var playRequest = 0
    @State private var showingReview = false
    @State private var graphService = KnowledgeGraphQueryService()
    @State private var entityAsk: KnowledgeEntityAskRequest?
    @State private var exportDocument: KnowledgeExportDocument?
    @State private var exportFailed = false
    @Environment(ChatConversationHost.self) private var conversations: ChatConversationHost?

    init(meetingIDs: Set<UUID>, initialEntityID: UUID? = nil, initialEvidenceSelection: KnowledgeEvidenceSelection? = nil,
         showsDone: Bool = true, scopeLabel: String = "", onChooseSources: (() -> Void)? = nil,
         onOpenSettings: (() -> Void)? = nil) {
        self.meetingIDs = meetingIDs
        self.showsDone = showsDone
        self.scopeLabel = scopeLabel
        self.onChooseSources = onChooseSources
        self.onOpenSettings = onOpenSettings
        _path = State(initialValue: initialEvidenceSelection.map { [.evidence(assertionID: $0.assertionID, evidenceID: $0.evidenceID)] }
            ?? initialEntityID.map { [.entity($0)] } ?? [])
    }

    private var selection: KnowledgeEvidenceSelection? { path.last?.evidenceSelection }
    private var requestKey: String {
        meetingIDs.map(\.uuidString).sorted().joined(separator: ",") + ":\(path):\(refresh)"
    }
    private var searchKey: String { "\(requestKey):\(settings.semanticSearchEnabled):\(searchRevision)" }
    private func exportKnowledge() {
        Task {
            do {
                let data = try await coordinator.exportKnowledge(meetingIDs: meetingIDs)
                if settings.knowledgeExportEnabled { exportDocument = KnowledgeExportDocument(data: data) }
            } catch {
                exportFailed = true
            }
        }
    }

    private var state: KnowledgeBrowserLoadState {
        settings.knowledgeEnabled ? model.presentation(meetingIDs: meetingIDs, selection: selection) : .unavailable
    }

    var body: some View {
        // Keep read/audio lifecycle outside NavigationStack's destination
        // lifecycle: pushing a page must not cancel the reader's owner.
        ZStack {
            NavigationStack(path: $path) {
                destination(nil)
                    // Keep the search controller installed while canonical
                    // content reloads; conditional registration can tear down
                    // its owner while a query task is still in flight.
                    .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(KnowledgeBrowserCopy.text("search_prompt")))
                    .searchFocused($searchFocused)
                    .onSubmit(of: .search) { searchFocused = false }
                    .navigationDestination(for: KnowledgeBrowserRoute.self) { destination($0) }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button { invalidateAndRefresh() } label: {
                                    Label(KnowledgeBrowserCopy.text("refresh"), systemImage: "arrow.clockwise")
                                }
                                .accessibilityIdentifier("knowledge.browser.refresh")
                                if settings.knowledgeExportEnabled {
                                    Button { exportKnowledge() } label: {
                                        Label(KnowledgeBrowserCopy.text("export"), systemImage: "square.and.arrow.up")
                                    }
                                    .accessibilityIdentifier("knowledge.browser.export")
                                }
                                if let onOpenSettings {
                                    Button(action: onOpenSettings) {
                                        Label(KnowledgeBrowserCopy.text("settings"), systemImage: "gearshape")
                                    }
                                }
                            } label: {
                                Label(KnowledgeBrowserCopy.text("actions"), systemImage: "ellipsis")
                            }
                            .accessibilityLabel(KnowledgeBrowserCopy.text("actions"))
                            .accessibilityIdentifier("knowledge.actions")
                        }
                        if showsDone {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingReview) { KnowledgeReviewInboxView(meetingIDs: meetingIDs) }
        // A save to a chosen location, never the generic share sheet (private-corporate boundary).
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json, defaultFilename: "Wiki") { result in
            if case .failure = result { exportFailed = true }
        }
        .alert(KnowledgeBrowserCopy.text("export_failed"), isPresented: $exportFailed) {}
        // Turning export off withdraws a bundle still waiting for its save location.
        .onChange(of: settings.knowledgeExportEnabled) { _, enabled in if !enabled { exportDocument = nil } }
        .sheet(item: $entityAsk) { request in
            NavigationStack {
                MeetingChatView(meeting: nil, conversation: request.conversation, initialScope: request.scope,
                                initialDraft: String(format: KnowledgeBrowserCopy.text("ask_draft"), request.name))
                    .navigationTitle(request.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("common.done", comment: "Done")) { entityAsk = nil }
                        }
                    }
            }
        }
        .task(id: requestKey) {
            if refresh > 0 {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            await model.load(meetingIDs: meetingIDs, selection: selection, isEnabled: { settings.knowledgeEnabled }, reader: read)
        }
        .task(id: searchKey) {
            guard path.isEmpty else { searchModel.invalidate(); return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            await searchModel.search(query: searchQuery, meetingIDs: meetingIDs, useSemantic: settings.semanticSearchEnabled,
                isEnabled: { settings.knowledgeEnabled }, reader: { try await coordinator.readKnowledgeBrowser(meetingIDs: meetingIDs) })
        }
        .task(id: playRequest) {
            guard playRequest > 0 else { return }
            await model.playEvidence(isEnabled: { settings.knowledgeEnabled }, reader: read)
        }
        .onChange(of: searchQuery) { _, _ in
            // Bump after invalidation, rather than racing an input-keyed task
            // against onChange and leaving its completed results cleared.
            searchModel.invalidate()
            searchRevision += 1
        }
        .onChange(of: settings.semanticSearchEnabled) { _, _ in invalidateAndRefresh() }
        .onChange(of: path) { _, _ in searchFocused = false; invalidateAndRefresh() }
        .onChange(of: settings.knowledgeEnabled) { _, _ in invalidateAndRefresh() }
        .onChange(of: settings.knowledgeControls) { _, _ in showingReview = false; invalidateAndRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave).receive(on: RunLoop.main)) { _ in
            invalidateAndRefresh()
        }
        .onChange(of: phase) { _, phase in
            if phase == .active { invalidateAndRefresh() } else { model.invalidate(); searchModel.invalidate(); graphService.clear() }
        }
        .onDisappear { model.invalidate(); searchModel.invalidate(); graphService.clear() }
    }

    private func read() async throws -> KnowledgeBrowserRead {
        try await coordinator.readKnowledgeBrowser(meetingIDs: meetingIDs, selection: selection)
    }

    private func invalidateAndRefresh() {
        model.invalidate()
        searchModel.invalidate()
        refresh += 1
    }

    @ViewBuilder
    private func destination(_ route: KnowledgeBrowserRoute?) -> some View {
        Group {
            switch state {
            case .idle, .loading:
                ProgressView(NSLocalizedString("detail.knowledge.loading", comment: "Loading"))
                    .accessibilityIdentifier("knowledge.browser.loading")
            case .unavailable:
                KnowledgeBrowserUnavailable()
            case let .loaded(read):
                loadedDestination(route, read: read)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle(title(route))
        .navigationBarTitleDisplayMode(route == nil || routeIsEntityPage(route!) ? .large : .inline)
    }

    @ViewBuilder
    private func loadedDestination(_ route: KnowledgeBrowserRoute?, read: KnowledgeBrowserRead) -> some View {
        switch route {
        case nil:
            Group {
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    KnowledgeHomeView(read: read, scopeLabel: scopeLabel,
                                      onChooseSources: onChooseSources, onOpenReview: { showingReview = true })
                } else {
                    KnowledgeSearchResultsView(query: searchQuery,
                        state: searchModel.presentation(query: searchQuery, meetingIDs: meetingIDs), scopeCount: meetingIDs.count)
                }
            }
        case let .entity(id):
            if let page = read.pages.first(where: { $0.entity.id == id }) {
                KnowledgeEntityPageView(page: page, meetingTitles: read.meetingTitles, onAsk: { scope in
                    entityAsk = KnowledgeEntityAskRequest(name: page.entity.name, scope: scope,
                        conversation: conversations?.standaloneConversation() ?? MeetingChatViewModel())
                }, navigate: { path.append($0) })
            } else { KnowledgeBrowserUnavailable() }
        case .timeline:
            KnowledgeTimelineView(read: read)
        case let .compare(id):
            if let page = read.pages.first(where: { $0.entity.id == id }) {
                KnowledgeCompareView(page: page, pages: read.pages)
            } else { KnowledgeBrowserUnavailable() }
        case let .graph(id):
            if read.pages.contains(where: { $0.entity.id == id }) {
                KnowledgeGraphView(read: read, entityID: id, service: graphService)
            } else { KnowledgeBrowserUnavailable() }
        case .evidence:
            if let source = read.selectedEvidence {
                KnowledgeEvidenceDetailView(source: source, isPlaying: model.isPlaying, isLoadingAudio: model.isLoadingAudio) {
                    if model.isPlaying { model.stopAudio() } else { playRequest += 1 }
                }
            } else { KnowledgeBrowserUnavailable() }
        case .transcript:
            if let source = read.selectedEvidence {
                KnowledgeSourceTranscriptView(source: source, isPlaying: model.isPlaying, isLoadingAudio: model.isLoadingAudio) {
                    if model.isPlaying { model.stopAudio() } else { playRequest += 1 }
                }
            } else { KnowledgeBrowserUnavailable() }
        }
    }

    /// The entity page reads like a wiki page with its large title.
    private func routeIsEntityPage(_ route: KnowledgeBrowserRoute) -> Bool {
        if case .entity = route { return true }
        return false
    }

    private func title(_ route: KnowledgeBrowserRoute?) -> String {
        switch route {
        case let .entity(id):
            if case let .loaded(read) = state, let page = read.pages.first(where: { $0.entity.id == id }) { return page.entity.name }
            return KnowledgeBrowserCopy.text("title")
        case .timeline: return KnowledgeBrowserCopy.text("timeline")
        case .compare: return KnowledgeComparePresentation.copy("title")
        case .graph: return KnowledgeGraphPresentation.copy("title")
        case .evidence: return KnowledgeBrowserCopy.text("evidence")
        case .transcript: return KnowledgeBrowserCopy.text("transcript")
        case nil: return KnowledgeBrowserCopy.text("title")
        }
    }
}

/// An Ask about an entity, in a conversation of its own so the library Ask keeps its scope.
struct KnowledgeEntityAskRequest: Identifiable {
    let id = UUID()
    let name: String
    let scope: ChatSourceScope
    let conversation: MeetingChatViewModel
}

enum KnowledgeBrowserCopy {
    static func text(_ key: String) -> String { NSLocalizedString("knowledge.browser." + key, comment: "Knowledge reader") }
}

struct KnowledgeBrowserUnavailable: View {
    var body: some View {
        ContentUnavailableView(NSLocalizedString("detail.knowledge.unavailable", comment: "Unavailable"), systemImage: "lock.doc",
            description: Text(NSLocalizedString("detail.knowledge.unavailable_detail", comment: "Access/source changed")))
    }
}

struct KnowledgeHomeView: View {
    let read: KnowledgeBrowserRead
    var scopeLabel: String = ""
    var onChooseSources: (() -> Void)?
    var onOpenReview: (() -> Void)?

    /// Pages with a fact recorded today lead the home as "Updated today".
    private var updatedToday: [KnowledgeWikiPage] {
        let calendar = Calendar.current
        return read.pages.filter { page in
            page.sections.flatMap(\.entries).contains { calendar.isDateInToday($0.fact.source.recordedAt) }
        }
    }

    private func facts(_ page: KnowledgeWikiPage) -> [KnowledgeWikiPage.Entry] {
        page.sections.flatMap(\.entries)
    }

    private func subtitle(_ page: KnowledgeWikiPage) -> String {
        let entries = facts(page)
        let kind = NSLocalizedString("knowledge.entity_kind." + page.entity.kind.rawValue, comment: "Entity kind")
        let meetings = Set(entries.map(\.fact.source.meetingID)).count
        return String(format: KnowledgeBrowserCopy.text("page_subtitle"), kind,
                      knowledgeCountText("knowledge.count.fact", entries.count),
                      knowledgeCountText("knowledge.count.meeting", meetings))
    }

    var body: some View {
        if read.pages.isEmpty {
            VStack(alignment: .leading) {
                scopeChip.padding(.horizontal, 20)
                ContentUnavailableView(NSLocalizedString("detail.knowledge.empty", comment: "No contributions"), systemImage: "book.closed")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    scopeChip
                    KnowledgeSectionLabel(KnowledgeBrowserCopy.text("explore")).padding(.top, 14)
                    VStack(spacing: 0) {
                        exploreRow
                        if let onOpenReview {
                            Divider().overlay(Theme.separator).padding(.leading, 58).accessibilityHidden(true)
                            Button(action: onOpenReview) {
                                HStack(spacing: 12) {
                                    KnowledgeIconWell(systemImage: "tray.full")
                                    Text(KnowledgeReviewCopy.text("title")).font(Theme.subheadline).foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    KnowledgeChevron()
                                }
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("knowledge.review.open")
                        }
                    }
                    .knowledgeGroup()
                    let today = updatedToday
                    let rest = read.pages.filter { page in !today.contains(where: { $0.entity.id == page.entity.id }) }
                    if !today.isEmpty {
                        KnowledgeSectionLabel(KnowledgeBrowserCopy.text("updated_today")).padding(.top, 14)
                        pageGroup(today)
                        if !rest.isEmpty {
                            KnowledgeSectionLabel(KnowledgeBrowserCopy.text("all_pages")).padding(.top, 14)
                            pageGroup(rest)
                        }
                    } else {
                        KnowledgeSectionLabel(KnowledgeBrowserCopy.text("pages")).padding(.top, 14)
                        pageGroup(read.pages)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
            }
            .accessibilityIdentifier("knowledge.browser.home")
        }
    }

    /// "This week · N meetings ⌄" — the selection's name and count.
    @ViewBuilder
    private var scopeChip: some View {
        if let onChooseSources {
            Button(action: onChooseSources) {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet").accessibilityHidden(true)
                    Text(verbatim: scopeLabel.isEmpty
                         ? knowledgeCountText("knowledge.count.meeting", read.meetingIDs.count)
                         : scopeLabel + " · " + knowledgeCountText("knowledge.count.meeting", read.meetingIDs.count))
                    Image(systemName: "chevron.down").font(Theme.caption2).accessibilityHidden(true)
                }
                .font(Theme.footnoteEmphasized)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Theme.fill, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("knowledge.chooseSources")
        }
    }

    @ViewBuilder
    private var exploreRow: some View {
        VStack(spacing: 0) {
            KnowledgeLinkCard(route: KnowledgeBrowserRoute.timeline) {
                HStack(spacing: 12) {
                    KnowledgeIconWell(systemImage: "clock")
                    Text(KnowledgeBrowserCopy.text("timeline")).font(Theme.subheadline).foregroundStyle(Theme.textPrimary)
                }
            }
            .accessibilityIdentifier("knowledge.browser.timeline")
            if let root = mostMentionedPage {
                Divider().overlay(Theme.separator).padding(.leading, 58).accessibilityHidden(true)
                KnowledgeLinkCard(route: KnowledgeBrowserRoute.graph(root.entity.id)) {
                    HStack(spacing: 12) {
                        KnowledgeIconWell(systemImage: "point.3.connected.trianglepath.dotted")
                        Text(KnowledgeBrowserCopy.text("relations")).font(Theme.subheadline).foregroundStyle(Theme.textPrimary)
                    }
                }
                .accessibilityIdentifier("knowledge.browser.relations")
            }
        }
    }

    /// The page with the most facts is where the graph opens from home.
    private var mostMentionedPage: KnowledgeWikiPage? {
        read.pages.max { facts($0).count < facts($1).count }
    }

    private func pageGroup(_ pages: [KnowledgeWikiPage]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(pages.enumerated()), id: \.element.entity.id) { index, page in
                if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 58).accessibilityHidden(true) }
                KnowledgeLinkCard(route: KnowledgeBrowserRoute.entity(page.entity.id)) {
                    HStack(spacing: 12) {
                        KnowledgeIconWell(systemImage: "book")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: page.entity.name).font(Theme.subheadline).foregroundStyle(Theme.textPrimary)
                            Text(verbatim: subtitle(page)).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                }
                .accessibilityIdentifier("knowledge.browser.entity")
            }
        }
        .knowledgeGroup()
    }
}

/// The K6.2 export bundle as a JSON document for `fileExporter`.
struct KnowledgeExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
