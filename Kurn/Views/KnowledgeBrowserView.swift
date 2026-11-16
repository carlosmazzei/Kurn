import Combine
import CoreData
import KurnCore
import SwiftUI

/// A scoped reading stack. Production enters from a meeting; the proposed
/// library-level root remains a DEBUG-only navigation review prototype.
struct KnowledgeBrowserView: View {
    let meetingIDs: Set<UUID>
    var initialEntityID: UUID?
    var showsDone = true
    @Environment(KnowledgeCompilationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var model = KnowledgeBrowserViewModel()
    @State private var path: [KnowledgeBrowserRoute] = []
    @State private var refresh = 0
    @State private var playRequest = 0

    private var selection: KnowledgeEvidenceSelection? { path.last?.evidenceSelection }
    private var requestKey: String {
        meetingIDs.map(\.uuidString).sorted().joined(separator: ",") + ":\(path):\(refresh)"
    }
    private var state: KnowledgeBrowserLoadState {
        settings.knowledgeEnabled ? model.presentation(meetingIDs: meetingIDs, selection: selection) : .unavailable
    }

    var body: some View {
        NavigationStack(path: $path) {
            destination(nil)
                .navigationDestination(for: KnowledgeBrowserRoute.self) { destination($0) }
                .toolbar {
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
        .task(id: requestKey) {
            if refresh > 0 {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            await model.load(meetingIDs: meetingIDs, selection: selection, isEnabled: { settings.knowledgeEnabled }, reader: read)
        }
        .task(id: playRequest) {
            guard playRequest > 0 else { return }
            await model.playEvidence(isEnabled: { settings.knowledgeEnabled }, reader: read)
        }
        .onAppear {
            if path.isEmpty, let initialEntityID { path = [.entity(initialEntityID)] }
        }
        .onChange(of: path) { _, _ in model.invalidate() }
        .onChange(of: settings.knowledgeEnabled) { _, _ in invalidateAndRefresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave).receive(on: RunLoop.main)) { _ in
            invalidateAndRefresh()
        }
        .onChange(of: phase) { _, phase in
            if phase == .active { invalidateAndRefresh() } else { model.invalidate() }
        }
        .onDisappear { model.invalidate() }
    }

    private func read() async throws -> KnowledgeBrowserRead {
        try await coordinator.readKnowledgeBrowser(meetingIDs: meetingIDs, selection: selection)
    }

    private func invalidateAndRefresh() {
        model.invalidate()
        refresh += 1
    }

    @ViewBuilder
    private func destination(_ route: KnowledgeBrowserRoute?) -> some View {
        Group {
            switch state {
            case .idle, .loading:
                ProgressView(NSLocalizedString("detail.knowledge.loading", comment: "Loading"))
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
            KnowledgeHomeView(read: read)
        case let .entity(id):
            if let page = read.pages.first(where: { $0.entity.id == id }) {
                KnowledgeEntityPageView(page: page, meetingTitles: read.meetingTitles)
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
