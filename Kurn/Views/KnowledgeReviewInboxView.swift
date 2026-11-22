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
        .onChange(of: settings.knowledgeControls) { _, _ in reload() }
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                notices(read)
                KnowledgeSectionLabel(KnowledgeReviewCopy.text("identities")).padding(.top, 8)
                let open = read.candidates.filter { !$0.isDismissed }
                if open.isEmpty { emptyCard } else { ForEach(open) { candidate in candidateLink(candidate) } }
                KnowledgeSectionLabel(KnowledgeReviewCopy.text("warnings")).padding(.top, 8)
                if read.warnings.isEmpty { emptyCard } else { ForEach(read.warnings) { warning in warningCard(warning) } }
                KnowledgeSectionLabel(KnowledgeReviewCopy.text("history")).padding(.top, 8)
                ForEach(read.merges) { merge in mergeCard(merge, allowsMutation: read.allowsMutation) }
                ForEach(read.candidates.filter(\.isDismissed)) { candidate in candidateLink(candidate) }
                if read.merges.isEmpty && !read.candidates.contains(where: \.isDismissed) { emptyCard }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
        .knowledgeReadingSurface()
        .accessibilityIdentifier("knowledge.review.inbox")
    }

    @ViewBuilder
    private func notices(_ read: KnowledgeReviewRead) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            notice(KnowledgeReviewCopy.text("intro"))
            if !read.allowsMutation { notice(KnowledgeReviewCopy.text("read_only")) }
            if read.isTruncated { notice(KnowledgeReviewCopy.text("limited")) }
            if model.decisionFailed {
                notice(KnowledgeReviewCopy.text("decision_failed")).accessibilityIdentifier("knowledge.review.failed")
            }
            if read.evidenceUnavailable {
                notice(KnowledgeReviewCopy.text("evidence_unavailable")).accessibilityIdentifier("knowledge.review.evidenceUnavailable")
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).font(Theme.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    private var emptyCard: some View {
        Text(KnowledgeReviewCopy.text("none")).font(Theme.subheadline).foregroundStyle(Theme.textSecondary).knowledgeCard()
    }

    private func warningCard(_ warning: KnowledgeReviewRead.Warning) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                notice(KnowledgeReviewCopy.text(warning.kind == .conflict ? "conflict_detail" : "date_detail"))
                ForEach(Array(warning.entries.prefix(16)), id: \.fact.id) { entry in
                    Divider().overlay(Theme.separator).accessibilityHidden(true)
                    Text(verbatim: entry.subject.name).font(Theme.subheadlineEmphasized).foregroundStyle(Theme.textPrimary)
                    ForEach(Array(entry.fact.source.evidence.prefix(3)), id: \.id) { passage in
                        KnowledgeQuote(text: passage.quote)
                        KnowledgeChipButton(title: KnowledgeReviewCopy.text("open_evidence"), systemImage: "text.quote") {
                            evidence = EvidenceRoute(selection: .init(assertionID: entry.fact.id, evidenceID: passage.id))
                        }
                        .accessibilityIdentifier("knowledge.review.evidence")
                    }
                }
                if warning.entries.count > 16 || warning.entries.contains(where: { $0.fact.source.evidence.count > 3 }) {
                    notice(KnowledgeReviewCopy.text("limited"))
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                KnowledgeIconWell(systemImage: warning.kind == .conflict ? "exclamationmark.triangle" : "calendar", tint: Theme.warning)
                Text(KnowledgeReviewCopy.text(warning.kind == .conflict ? "conflict" : "date"))
                    .font(Theme.headline).foregroundStyle(Theme.textPrimary)
            }
        }
        .tint(Theme.textSecondary)
        .knowledgeCard()
    }

    private func mergeCard(_ merge: KnowledgeReviewRead.Merge, allowsMutation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                KnowledgeIconWell(systemImage: "arrow.triangle.merge", tint: Theme.info)
                Text(verbatim: merge.sourceName + " → " + merge.targetName)
                    .font(Theme.subheadlineEmphasized).foregroundStyle(Theme.textPrimary)
            }
            if merge.isUndone {
                Text(KnowledgeReviewCopy.text("undone")).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            } else {
                KnowledgeChipButton(title: KnowledgeReviewCopy.text("undo"), systemImage: "arrow.uturn.backward") { decide(.undo(merge.id)) }
                    .disabled(!allowsMutation)
                    .accessibilityIdentifier("knowledge.review.undo")
            }
        }
        .knowledgeCard()
    }

    private func candidateLink(_ candidate: KnowledgeReviewRead.Candidate) -> some View {
        KnowledgeLinkCard(route: candidate.id) {
            HStack(spacing: 12) {
                KnowledgeIconWell(systemImage: candidate.isDismissed ? "person.2.slash" : "person.2")
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: candidate.source.name + " · " + candidate.target.name)
                        .font(Theme.subheadlineEmphasized).foregroundStyle(Theme.textPrimary)
                    Text(KnowledgeReviewCopy.text(candidate.isDismissed ? "kept_separate" : "possible_match"))
                        .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
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
