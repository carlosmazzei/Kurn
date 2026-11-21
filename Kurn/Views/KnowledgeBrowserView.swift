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
         showsDone: Bool = true, onChooseSources: (() -> Void)? = nil) {
        self.meetingIDs = meetingIDs
        self.showsDone = showsDone
        self.onChooseSources = onChooseSources
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
                exportDocument = KnowledgeExportDocument(data: try await coordinator.exportKnowledge(meetingIDs: meetingIDs))
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
                        if let onChooseSources {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(action: onChooseSources) {
                                    Label(KnowledgeBrowserCopy.text("choose_sources"), systemImage: "checklist")
                                }
                                .accessibilityIdentifier("knowledge.chooseSources")
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { showingReview = true } label: { Label(KnowledgeReviewCopy.text("title"), systemImage: "tray.full") }
                                .accessibilityIdentifier("knowledge.review.open")
                        }
                        if settings.knowledgeExportEnabled {
                            ToolbarItem(placement: .primaryAction) {
                                Button { exportKnowledge() } label: {
                                    Label(KnowledgeBrowserCopy.text("export"), systemImage: "square.and.arrow.up")
                                }
                                .accessibilityIdentifier("knowledge.browser.export")
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button { invalidateAndRefresh() } label: { Label(KnowledgeBrowserCopy.text("refresh"), systemImage: "arrow.clockwise") }
                                .accessibilityIdentifier("knowledge.browser.refresh")
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
                      document: exportDocument, contentType: .json, defaultFilename: "Knowledge") { result in
            if case .failure = result { exportFailed = true }
        }
        .alert(KnowledgeBrowserCopy.text("export_failed"), isPresented: $exportFailed) {}
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
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func loadedDestination(_ route: KnowledgeBrowserRoute?, read: KnowledgeBrowserRead) -> some View {
        switch route {
        case nil:
            Group {
                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    KnowledgeHomeView(read: read)
                } else {
                    KnowledgeSearchResultsView(query: searchQuery,
                        state: searchModel.presentation(query: searchQuery, meetingIDs: meetingIDs), scopeCount: meetingIDs.count)
                }
            }
        case let .entity(id):
            if let page = read.pages.first(where: { $0.entity.id == id }) {
                KnowledgeEntityPageView(page: page, meetingTitles: read.meetingTitles) { scope in
                    entityAsk = KnowledgeEntityAskRequest(name: page.entity.name, scope: scope,
                        conversation: conversations?.standaloneConversation() ?? MeetingChatViewModel())
                }
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
            if let source = read.selectedEvidence { KnowledgeEvidenceDetailView(source: source) }
            else { KnowledgeBrowserUnavailable() }
        case .transcript:
            if let source = read.selectedEvidence {
                KnowledgeSourceTranscriptView(source: source, isPlaying: model.isPlaying, isLoadingAudio: model.isLoadingAudio) {
                    if model.isPlaying { model.stopAudio() } else { playRequest += 1 }
                }
            } else { KnowledgeBrowserUnavailable() }
        }
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

    var body: some View {
        if read.pages.isEmpty {
            ContentUnavailableView(NSLocalizedString("detail.knowledge.empty", comment: "No contributions"), systemImage: "book.closed")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    KnowledgeLinkCard(route: KnowledgeBrowserRoute.timeline) {
                        HStack(spacing: 12) {
                            KnowledgeIconWell(systemImage: "calendar.day.timeline.leading", tint: Theme.info)
                            Text(KnowledgeBrowserCopy.text("timeline")).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .accessibilityIdentifier("knowledge.browser.timeline")
                    KnowledgeSectionLabel(String(format: KnowledgeBrowserCopy.text("scope"), read.meetingIDs.count))
                        .padding(.top, 14)
                    ForEach(read.pages, id: \.entity.id) { page in
                        KnowledgeLinkCard(route: KnowledgeBrowserRoute.entity(page.entity.id)) {
                            HStack(spacing: 12) {
                                KnowledgeIconWell(systemImage: "book.pages")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: page.entity.name).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                                    if !page.entity.aliases.isEmpty {
                                        Text(verbatim: page.entity.aliases.joined(separator: " · "))
                                            .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("knowledge.browser.entity")
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
            }
            .accessibilityIdentifier("knowledge.browser.home")
        }
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
