import Combine
import CoreData
import KurnCore
import SwiftUI

/// An explicitly scoped reader/search stack, shared by meeting entry and the
/// reviewed Knowledge root. Navigation carries IDs, never cached search text.
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
                    .navigationDestination(for: KnowledgeBrowserRoute.self) {
                        destination($0).toolbar(.hidden, for: .tabBar)
                    }
                    // The root destinations draw their own bar; the stack's
                    // own pages keep the native tab bar hidden as well, since
                    // a hosting tab's modifier does not always reach inside
                    // a stack whose root changes as content loads. In a sheet
                    // there is no tab bar, so this changes nothing there.
                    .toolbar(.hidden, for: .tabBar)
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
                KnowledgeEntityPageView(page: page, meetingTitles: read.meetingTitles)
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
            List {
                Section {
                    NavigationLink(value: KnowledgeBrowserRoute.timeline) {
                        Label(KnowledgeBrowserCopy.text("timeline"), systemImage: "calendar.day.timeline.leading")
                    }
                    .accessibilityIdentifier("knowledge.browser.timeline")
                }
                Section {
                    ForEach(read.pages, id: \.entity.id) { page in
                        NavigationLink(value: KnowledgeBrowserRoute.entity(page.entity.id)) {
                            Text(verbatim: page.entity.name).font(Theme.headline)
                        }
                        .accessibilityIdentifier("knowledge.browser.entity")
                    }
                } header: {
                    Text(String(format: KnowledgeBrowserCopy.text("scope"), read.meetingIDs.count))
                }
            }
            .accessibilityIdentifier("knowledge.browser.home")
        }
    }
}
