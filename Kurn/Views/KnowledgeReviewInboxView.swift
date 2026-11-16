import Combine
import CoreData
import SwiftUI

struct KnowledgeReviewInboxView: View {
    let meetingIDs: Set<UUID>
    @Environment(KnowledgeCompilationCoordinator.self) private var coordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var model = KnowledgeReviewViewModel()
    @State private var refresh = 0
    @State private var path: [UUID] = []
    @State private var pending: KnowledgeReviewCommand?
    @State private var evidence: EvidenceRoute?

    private struct EvidenceRoute: Identifiable {
        let selection: KnowledgeEvidenceSelection
        var id: KnowledgeEvidenceSelection { selection }
    }

    private var state: KnowledgeReviewLoadState {
        settings.knowledgeEnabled ? model.presentation(meetingIDs: meetingIDs) : .unavailable
    }
    private var loadKey: String { meetingIDs.map(\.uuidString).sorted().joined(separator: ":") + ":\(refresh)" }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(KnowledgeReviewCopy.text("title"))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: UUID.self) { id in
                    if case let .loaded(read) = state, let candidate = read.candidates.first(where: { $0.id == id }) {
                        KnowledgeIdentityReviewView(candidate: candidate, allowsMutation: read.allowsMutation, decide: decide)
                    } else { KnowledgeBrowserUnavailable() }
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { reload() } label: { Label(KnowledgeBrowserCopy.text("refresh"), systemImage: "arrow.clockwise") }
                            .disabled(model.isWorking)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("knowledge.review.done")
                    }
                }
        }
        .interactiveDismissDisabled(model.isWorking)
        .sheet(item: $evidence) { route in
            KnowledgeBrowserView(meetingIDs: meetingIDs, initialEvidenceSelection: route.selection)
        }
        .task(id: loadKey) {
            if refresh > 0 { do { try await Task.sleep(for: .milliseconds(150)) } catch { return } }
            await model.load(meetingIDs: meetingIDs, isEnabled: { settings.knowledgeEnabled }, reader: read)
        }
        .task(id: pending) {
            guard let pending else { return }
            await model.perform(pending, meetingIDs: meetingIDs, isEnabled: { settings.knowledgeEnabled }, reader: read,
                writer: { try await coordinator.decideKnowledgeReview($0, snapshot: $1) })
            self.pending = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextDidSave).receive(on: RunLoop.main)) { _ in reload() }
        .onChange(of: settings.knowledgeEnabled) { _, _ in reload() }
        .onChange(of: meetingIDs) { _, _ in path = []; reload() }
        .onChange(of: phase) { _, value in if value == .active { reload() } else { clear() } }
        .onDisappear { model.invalidate() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle, .loading: ProgressView().accessibilityIdentifier("knowledge.review.loading")
        case .unavailable: KnowledgeBrowserUnavailable()
        case let .loaded(read): inbox(read)
        }
    }

    private func inbox(_ read: KnowledgeReviewRead) -> some View {
        List {
            Section {
                Text(KnowledgeReviewCopy.text("intro")).foregroundStyle(.secondary)
                if !read.allowsMutation { Text(KnowledgeReviewCopy.text("read_only")) }
                if read.isTruncated { Text(KnowledgeReviewCopy.text("limited")) }
                if model.decisionFailed { Text(KnowledgeReviewCopy.text("decision_failed")).accessibilityIdentifier("knowledge.review.failed") }
                if read.evidenceUnavailable { Text(KnowledgeReviewCopy.text("evidence_unavailable")).accessibilityIdentifier("knowledge.review.evidenceUnavailable") }
            }
            Section(KnowledgeReviewCopy.text("identities")) {
                ForEach(read.candidates.filter { !$0.isDismissed }) { candidate in candidateLink(candidate) }
                if !read.candidates.contains(where: { !$0.isDismissed }) { Text(KnowledgeReviewCopy.text("none")) }
            }
            Section(KnowledgeReviewCopy.text("warnings")) {
                ForEach(read.warnings) { warning in
                    DisclosureGroup {
                        Text(KnowledgeReviewCopy.text(warning.kind == .conflict ? "conflict_detail" : "date_detail"))
                        ForEach(Array(warning.entries.prefix(16)), id: \.fact.id) { entry in
                            Text(verbatim: entry.subject.name).font(.headline)
                            ForEach(Array(entry.fact.source.evidence.prefix(3)), id: \.id) { passage in
                                Text(verbatim: passage.quote)
                                Button(KnowledgeReviewCopy.text("open_evidence")) {
                                    evidence = EvidenceRoute(selection: .init(assertionID: entry.fact.id, evidenceID: passage.id))
                                }
                                .accessibilityIdentifier("knowledge.review.evidence")
                            }
                        }
                        if warning.entries.count > 16 || warning.entries.contains(where: { $0.fact.source.evidence.count > 3 }) {
                            Text(KnowledgeReviewCopy.text("limited"))
                        }
                    } label: { Text(KnowledgeReviewCopy.text(warning.kind == .conflict ? "conflict" : "date")) }
                    .accessibilityIdentifier("knowledge.review.warning." + warning.kind.rawValue)
                }
                if read.warnings.isEmpty { Text(KnowledgeReviewCopy.text("none")) }
            }
            Section(KnowledgeReviewCopy.text("history")) {
                ForEach(read.merges) { merge in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: merge.sourceName + " → " + merge.targetName)
                        if merge.isUndone { Text(KnowledgeReviewCopy.text("undone")).foregroundStyle(.secondary) }
                        else {
                            Button(KnowledgeReviewCopy.text("undo")) { decide(.undo(merge.id)) }
                                .disabled(!read.allowsMutation)
                                .accessibilityIdentifier("knowledge.review.undo")
                        }
                    }
                }
                ForEach(read.candidates.filter(\.isDismissed)) { candidate in candidateLink(candidate) }
                if read.merges.isEmpty && !read.candidates.contains(where: \.isDismissed) { Text(KnowledgeReviewCopy.text("none")) }
            }
        }
        .accessibilityIdentifier("knowledge.review.inbox")
    }

    private func candidateLink(_ candidate: KnowledgeReviewRead.Candidate) -> some View {
        NavigationLink(value: candidate.id) {
            VStack(alignment: .leading) {
                Text(verbatim: candidate.source.name + " · " + candidate.target.name)
                Text(KnowledgeReviewCopy.text(candidate.isDismissed ? "kept_separate" : "possible_match")).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier(candidate.isDismissed ? "knowledge.review.dismissed" : "knowledge.review.candidate")
    }

    private func read() async throws -> KnowledgeReviewRead { try await coordinator.readKnowledgeReview(meetingIDs: meetingIDs) }
    private func decide(_ command: KnowledgeReviewCommand) { path = []; pending = command }
    private func clear() { pending = nil; evidence = nil; model.invalidate() }
    private func reload() { clear(); refresh += 1 }
}

enum KnowledgeReviewCopy {
    static func text(_ key: String) -> String { NSLocalizedString("knowledge.review." + key, comment: "Knowledge review") }
}
