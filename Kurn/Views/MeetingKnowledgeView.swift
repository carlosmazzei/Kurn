import KurnCore
import SwiftUI

/// The meeting Wiki tab: the extracted knowledge is the content — each fact
/// once, grouped by section kind, with its quote and a seek chip — and the
/// generated meeting page is a link row at the bottom that opens as a sheet.
struct MeetingKnowledgeView: View {
    let meeting: Meeting
    let state: MeetingKnowledgeState
    let isGeneratingArticle: Bool
    let canGenerateArticle: Bool
    /// Apple on-device generation revalidates the canonical read first; another provider uses the
    /// same explicit wiki generation the summary and transcript tabs' siblings use.
    let generatesLocally: Bool
    let onRefresh: () -> Void
    let onOpenPage: () -> Void
    /// Seek the recording a piece of evidence came from (recording-relative seconds).
    let onSeek: (UUID, TimeInterval) -> Void
    @Environment(KnowledgeCompilationCoordinator.self) private var coordinator
    @Environment(WikiCoordinator.self) private var wiki
    @Environment(AppSettings.self) private var settings
    @State private var selectedEntityID: UUID?

    /// The section order the tab shows — specific kinds first, generic claims last.
    private static let sectionOrder: [KnowledgeWikiPage.Kind] = [.decisions, .actions, .risks, .questions, .metrics, .claims]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if case let .loaded(read) = state, !read.contributions.isEmpty {
                    headerRow(read)
                    knowledgeProgressRow
                    compileResultNote
                    statusRow
                    factsSections(read)
                    pagesChips(read)
                    pageLinkRow
                } else {
                    knowledgeProgressRow
                    compileResultNote
                    statusRow
                    if case let .loaded(read) = state {
                        if read.contributions.isEmpty, meeting.wikiArticle != nil {
                            pageLinkRow
                        } else if read.contributions.isEmpty {
                            emptyState
                        }
                    } else {
                        statePlaceholder
                        if meeting.wikiArticle != nil { pageLinkRow }
                    }
                }
            }
            // The same insets as the Transcript and Summary tabs.
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
        .accessibilityIdentifier("knowledge.content")
        .sheet(isPresented: Binding(get: { selectedEntityID != nil }, set: { if !$0 { selectedEntityID = nil } })) {
            if let selectedEntityID { KnowledgeBrowserView(meetingIDs: [meeting.id], initialEntityID: selectedEntityID) }
        }
    }

    /// "<N> facts · <M> pages" with the refresh ghost on the right.
    private func headerRow(_ read: MeetingKnowledgeRead) -> some View {
        HStack {
            Text(verbatim: String(format: NSLocalizedString("detail.knowledge.changed_summary", comment: "Facts and pages"),
                                  knowledgeCountText("knowledge.count.fact", read.assertionCount),
                                  knowledgeCountText("knowledge.count.page", read.contributions.count)))
                .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("knowledge.header")
            Spacer()
            refreshButton
        }
    }

    /// The compile's live progress — the same shape as the Summary bar's
    /// generating state: a pill label, a thin determinate bar and a one-line
    /// stat row; the facts stay visible underneath at all times.
    @ViewBuilder
    private var knowledgeProgressRow: some View {
        if let progress = coordinator.progress(for: meeting.id) ?? (updateInFlight ? pendingProgress : nil) {
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("detail.knowledge.updating", comment: "Knowledge · updating…"))
                    .font(Theme.footnoteEmphasized).foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14).frame(minHeight: 32)
                    .background(Theme.fill, in: Capsule())
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.ink)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(updateStats(progress, at: context.date))
                        .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            .accessibilityIdentifier("knowledge.progress")
        }
    }

    /// The stat line "<phase> · <N%> · <model> · <elapsed>s · <N facts>" —
    /// the summary's generating line's order, with the phase in front.
    private func updateStats(_ progress: KnowledgeCompilationProgress, at now: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(progress.startedAt))
        let model = progress.modelLabel.isEmpty ? progress.providerLabel : progress.modelLabel
        return String(
            format: NSLocalizedString("detail.knowledge.update.stats", comment: "phase, percent, model, elapsed, facts"),
            progress.phase.displayName, Int((progress.fraction * 100).rounded()), model, elapsed,
            knowledgeCountText("knowledge.count.fact", progress.factsSoFar)
        )
    }

    /// What the just-finished compile published, briefly — a real count, the
    /// honest "the model found nothing" note, or nothing when it was a
    /// no-op replay that committed no new assertions.
    @ViewBuilder
    private var compileResultNote: some View {
        if let result = coordinator.result(for: meeting.id) {
            Text(result.factCount > 0
                 ? knowledgeCountText("knowledge.updated.fact", result.factCount)
                 : NSLocalizedString(result.modelEmpty ? "knowledge.updated_empty" : "knowledge.updated_none",
                                     comment: "No new facts"))
            .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            .transition(.opacity)
        }
    }

    /// Generation in flight or the last explicit failure — a row that joins and
    /// leaves without moving the facts underneath.
    @ViewBuilder
    private var statusRow: some View {
        if isGeneratingArticle {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(format: NSLocalizedString("detail.wiki.writing", comment: "Page being written"),
                            writerLabel))
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            }
        } else if let errorText = lastCompileErrorText ?? lastAttemptErrorText {
            HStack(spacing: 10) {
                Text(errorText)
                    .font(Theme.footnote).foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                if canGenerateArticle {
                    KnowledgeChipButton(title: NSLocalizedString("detail.try_again", comment: "Try again"),
                                        systemImage: "arrow.clockwise", action: generate)
                }
            }
        }
    }

    /// "Writing the meeting page · <provider/model>" — the same resolution the
    /// empty state's footnote uses, without the "Will use" framing.
    private var writerLabel: String {
        let provider = settings.wikiGenerationProvider
        let model = settings.wikiGenerationModel
        if provider.kind == .appleOnDevice {
            return NSLocalizedString("detail.generate.on_device", comment: "On-device generation")
        }
        return model.isEmpty ? provider.displayName : provider.displayName + " · " + model
    }

    /// Each fact once (the projector lists a claim on both its subject's and its
    /// object's page), grouped by the kind the projector assigns.
    private func factGroups(_ read: MeetingKnowledgeRead) -> [(KnowledgeWikiPage.Kind, [KnowledgeWikiPage.Entry])] {
        var seen = Set<UUID>()
        var entries: [KnowledgeWikiPage.Entry] = []
        for contribution in read.contributions {
            for entry in contribution.entries where seen.insert(entry.fact.id).inserted {
                entries.append(entry)
            }
        }
        return Self.sectionOrder.compactMap { kind in
            let group = entries.filter { KnowledgeWikiProjector.section($0) == kind }
            return group.isEmpty ? nil : (kind, group)
        }
    }

    private func factsSections(_ read: MeetingKnowledgeRead) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            KnowledgeSectionLabel(NSLocalizedString("detail.knowledge.facts_title", comment: "Knowledge from this meeting"))
            ForEach(factGroups(read), id: \.0) { kind, entries in
                Text(NSLocalizedString("knowledge.browser.section." + kind.rawValue, comment: "Fact section"))
                    .font(Theme.footnoteEmphasized).foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.fact.id) { index, entry in
                        if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 14).accessibilityHidden(true) }
                        MeetingFactRow(entry: entry, onOpen: { selectedEntityID = entry.subject.id }, onSeek: onSeek)
                    }
                }
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    /// The entity pages this meeting touched — one compact chip row, each chip
    /// opens the page in the Wiki reader sheet.
    private func pagesChips(_ read: MeetingKnowledgeRead) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            KnowledgeSectionLabel(NSLocalizedString("knowledge.browser.pages", comment: "Pages"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(read.contributions) { contribution in
                        Button { selectedEntityID = contribution.id } label: {
                            KnowledgeChipLabel(title: contribution.name, systemImage: "book")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// The generated meeting page, secondary to the facts: a link row into the
    /// sheet, or "No page yet" plus the small Generate chip.
    @ViewBuilder
    private var pageLinkRow: some View {
        if let article = meeting.wikiArticle {
            Button(action: onOpenPage) {
                HStack(spacing: 12) {
                    KnowledgeIconWell(systemImage: "book")
                    Text(verbatim: String(format: NSLocalizedString("detail.knowledge.page_written", comment: "Meeting page written"),
                                          article.updatedAt.shortTime))
                        .font(Theme.subheadline).foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    KnowledgeChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("knowledge.meetingPage")
        } else {
            HStack {
                Text(NSLocalizedString("detail.knowledge.no_page", comment: "No page yet"))
                    .font(Theme.subheadline).foregroundStyle(Theme.textSecondary)
                Spacer()
                if canGenerateArticle {
                    KnowledgeChipButton(title: NSLocalizedString("detail.wiki.generate", comment: "Generate page"),
                                        systemImage: "sparkles", action: generate)
                        .accessibilityIdentifier("knowledge.generateNotes")
                }
            }
        }
    }

    /// Only a meeting with neither a page nor contributions gets the shared
    /// "No page yet" empty state.
    private var emptyState: some View {
        MeetingGenerateEmptyState(
            systemImage: "book",
            title: NSLocalizedString("detail.knowledge.no_page", comment: "No page yet"),
            // `knowledge.header` rides on the description while the
            // counters line is hidden — the identifier stays findable.
            description: NSLocalizedString("detail.knowledge.no_page_detail", comment: "Generate a page"),
            descriptionIdentifier: "knowledge.header",
            actionTitle: canGenerateArticle
                ? NSLocalizedString("detail.wiki.generate", comment: "Generate page")
                : nil,
            actionIdentifier: "knowledge.generateNotes",
            footnote: wikiModelNudge,
            errorText: lastAttemptErrorText,
            action: generate
        )
    }

    @ViewBuilder
    private var statePlaceholder: some View {
        switch state {
        case .idle, .loading:
            ProgressView(NSLocalizedString("detail.knowledge.loading", comment: "Loading contributions"))
                .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity).padding(.top, 24)
        case .unavailable:
            ContentUnavailableView(NSLocalizedString("detail.knowledge.unavailable", comment: "Knowledge unavailable"), systemImage: "lock.doc",
                description: Text(NSLocalizedString("detail.knowledge.unavailable_detail", comment: "Access or source data changed")))
        case .loaded:
            EmptyView()
        }
    }

    /// The most recent explicit compile refusal for this meeting — surfaced
    /// identically whether the request came from the tab or the ⋯ menu, and
    /// an integrity-gate rejection reads as its own sentence.
    private var lastCompileErrorText: String? {
        guard coordinator.lastExplicitFailure?.meetingID == meeting.id,
              let code = coordinator.lastExplicitFailure?.code else { return nil }
        let isDeferredReason = KnowledgeJobDeferred.Reason(rawValue: code) != nil
            || code == "no_transcript" || code == "last_attempt_failed"
        let description = if KnowledgeExtractionError(rawValue: code) != nil {
            NSLocalizedString("knowledge.updated_rejected", comment: "Integrity check rejected output")
        } else if isDeferredReason {
            AppError.wikiGenerationDeferred(reason: code).errorDescription
                ?? AppError.wikiGenerationDeferred(reason: code).localizedDescription
        } else {
            NSLocalizedString("knowledge.update_failed", comment: "Generic knowledge update failure")
        }
        return String(format: NSLocalizedString("knowledge.last_attempt_failed", comment: "Inline failure reason"), description)
    }

    /// The most recent explicit failure's reason, only when it belongs to
    /// this meeting — automatic runs stay silent (logs only).
    private var lastAttemptErrorText: String? {
        guard wiki.lastErrorMeetingID == meeting.id, let error = wiki.lastError else { return nil }
        return String(format: NSLocalizedString("knowledge.last_attempt_failed", comment: "Inline wiki failure reason"),
                      error.errorDescription ?? error.localizedDescription)
    }

    /// "Update knowledge" — a forced explicit recompile with real progress.
    private var refreshButton: some View {
        KnowledgeChipButton(title: NSLocalizedString("detail.knowledge.update", comment: "Update knowledge"),
                            systemImage: "sparkles", action: updateKnowledge)
            .accessibilityIdentifier("knowledge.refresh")
    }

    /// Same provider·model nudge the Summary empty state shows — the Wiki
    /// writer resolves through `wikiGenerationProvider`/`wikiGenerationModel`
    /// (explicit pick, else "Same as summaries").
    private var wikiModelNudge: String {
        MeetingGenerateEmptyState.modelNudge(
            provider: settings.wikiGenerationProvider,
            model: settings.wikiGenerationModel
        )
    }

    /// True while a tab-initiated compile is anywhere before the worker —
    /// the progress row shows its first phase until real progress arrives.
    @State private var updateInFlight = false
    @State private var compileTask: Task<Void, Never>?

    /// Placeholder used between the tap and the worker's first phase report.
    private var pendingProgress: KnowledgeCompilationProgress {
        KnowledgeCompilationProgress(startedAt: Date(),
                                     providerLabel: settings.knowledgeProvider?.displayName ?? "",
                                     modelLabel: settings.knowledgeProvider.map { settings.summaryModel(for: $0) } ?? "")
    }

    private func updateKnowledge() {
        compileTask?.cancel()
        compileTask = Task { await updateKnowledgeRun() }
    }

    /// Forced explicit recompile — the failure reason lands on the
    /// coordinator's `lastExplicitFailure`, the count on its result note.
    private func updateKnowledgeRun() async {
        updateInFlight = true
        defer { updateInFlight = false }
        let outcome = await coordinator.compile(meetingID: meeting.id, trigger: .explicit, force: true)
        if outcome != .deferred { onRefresh() }
    }

    private func generate() {
        Task {
            // Regenerate rebuilds the facts first (knowledge progress row),
            // then the article (the wiki "Writing…" row) — sequential, the
            // facts underneath never move.
            await updateKnowledgeRun()
            if generatesLocally {
                _ = await coordinator.generateLocalMeetingNotes(meeting, wiki: wiki)
            } else {
                await wiki.generate(meeting, trigger: .explicit, force: true)
            }
        }
    }
}

/// One fact row: the plain claim sentence (tap → the subject's page in the
/// Wiki reader), an optional non-plain tag, then the quote with a `[m:ss]`
/// seek chip.
private struct MeetingFactRow: View {
    let entry: KnowledgeWikiPage.Entry
    let onOpen: () -> Void
    let onSeek: (UUID, TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpen) {
                Text(verbatim: MeetingKnowledgeClaimPresentation.sentence(entry))
                    .font(Theme.body).foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("knowledge.openEntity")
            if let tag {
                Text(tag)
                    .font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
            }
            if let evidence = entry.fact.source.evidence.first {
                HStack(alignment: .top, spacing: 8) {
                    Text(verbatim: evidence.quote)
                        .font(Theme.footnote).italic().foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("knowledge.quote")
                    Button {
                        onSeek(evidence.recordingID, TimeInterval(evidence.startMs) / 1_000)
                    } label: {
                        Text(verbatim: "[\((TimeInterval(evidence.startMs) / 1_000).clockDisplay)]")
                            .font(Theme.caption).monospacedDigit()
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Theme.fill, in: Capsule())
                            .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NSLocalizedString("knowledge.browser.play", comment: "Play from this passage"))
                    .accessibilityIdentifier("knowledge.seek")
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    /// Non-plain assertions only: a tentative/inferred modality tag and a
    /// "Negated" tag — a reported positive fact carries no badge.
    private var tag: String? {
        var parts: [String] = []
        if KnowledgeTemporalReducer.tentative.contains(entry.fact.qualifiers.modality)
            || entry.fact.qualifiers.modality == .inferred {
            parts.append(NSLocalizedString("knowledge.modality." + entry.fact.qualifiers.modality.rawValue, comment: "Claim modality"))
        }
        if entry.fact.qualifiers.polarity == .negative {
            parts.append(NSLocalizedString("detail.knowledge.negated", comment: "Negated claim"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
