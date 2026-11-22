import KurnCore
import SwiftUI

struct MeetingKnowledgeView: View {
    let meeting: Meeting
    let state: MeetingKnowledgeState
    /// The contribution counters line, formerly in the detail header — it
    /// moved here with the rest of the Wiki content (identifier kept).
    var headerText: String = ""
    let isGeneratingArticle: Bool
    let canGenerateArticle: Bool
    /// Apple on-device generation revalidates the canonical read first; another provider uses the
    /// same explicit wiki generation the summary and transcript tabs' siblings use.
    let generatesLocally: Bool
    let onRefresh: () -> Void
    @Environment(KnowledgeCompilationCoordinator.self) private var coordinator
    @Environment(WikiCoordinator.self) private var wiki
    @Environment(AppSettings.self) private var settings
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedEntityID: UUID?

    var body: some View {
        let hasPage = meeting.wikiArticle != nil
        let contributionsPresent: Bool = {
            if case let .loaded(read) = state { return !read.contributions.isEmpty }
            return false
        }()
        let stateIsLoaded: Bool = {
            if case .loaded = state { return true }
            return false
        }()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Only a meeting with neither a page nor contributions gets
                // the bare "No page yet" state — with contributions the
                // counters, a compact Generate row and "Changed pages" still
                // earn their place even while no page exists.
                if hasPage || contributionsPresent {
                    if !headerText.isEmpty {
                        Text(headerText)
                            .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("knowledge.header")
                    }
                    if hasPage { pageHeader }
                }
                if stateIsLoaded {
                    if hasPage || !contributionsPresent {
                        articleSection
                    } else {
                        compactPageRow
                    }
                }
                if hasPage || contributionsPresent || !stateIsLoaded {
                    if contributionsPresent, case let .loaded(read) = state {
                        contributionsHeader(read)
                    }
                    contributions
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

    /// "Meeting page" with the refresh ghost on the right.
    private var pageHeader: some View {
        HStack {
            Text(NSLocalizedString("detail.knowledge.notes", comment: "Meeting page"))
                .font(Theme.subheadlineEmphasized).foregroundStyle(Theme.textPrimary)
            Spacer()
            refreshButton
        }
    }

    /// "Changed pages" with the pages and facts totals underneath.
    private func contributionsHeader(_ read: MeetingKnowledgeRead) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            KnowledgeSectionLabel(NSLocalizedString("detail.knowledge.contributions", comment: "Changed pages"))
            Text(verbatim: String(format: NSLocalizedString("detail.knowledge.changed_summary", comment: "Pages and facts"),
                                  knowledgeCountText("knowledge.count.page", read.contributions.count),
                                  knowledgeCountText("knowledge.count.fact", read.contributions.reduce(0) { $0 + $1.entries.count })))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
    }

    /// Compact generate affordance for the no-page-with-contributions case —
    /// the big "No page yet" empty state would bury the real content.
    /// The most recent explicit failure's reason, only when it belongs to
    /// this meeting — automatic runs stay silent (logs only).
    private var lastAttemptErrorText: String? {
        guard wiki.lastErrorMeetingID == meeting.id, let error = wiki.lastError else { return nil }
        return String(format: NSLocalizedString("knowledge.last_attempt_failed", comment: "Inline wiki failure reason"),
                      error.errorDescription ?? error.localizedDescription)
    }

    @ViewBuilder
    private var compactPageRow: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 10) {
            if isGeneratingArticle {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("detail.wiki.generating", comment: "Generating meeting page"))
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            } else if canGenerateArticle {
                KnowledgeChipButton(title: NSLocalizedString("detail.wiki.generate", comment: "Generate page"),
                                    systemImage: "sparkles", action: generate)
                    .accessibilityIdentifier("knowledge.generateNotes")
            }
        }
            if let lastAttemptErrorText {
                Text(lastAttemptErrorText)
                    .font(Theme.footnote).foregroundStyle(Theme.destructive)
            }
        }
    }

    private var refreshButton: some View {
        KnowledgeChipButton(title: NSLocalizedString("detail.knowledge.refresh", comment: "Refresh contributions"),
                            systemImage: "arrow.clockwise", action: onRefresh)
            .accessibilityIdentifier("knowledge.refresh")
    }

    private var articleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let article = meeting.wikiArticle {
                MeetingWikiContent(article: article)
                    .accessibilityIdentifier("knowledge.notes")
                Label(String(format: NSLocalizedString("detail.wiki.provenance", comment: "AI provenance"),
                             article.updatedAt.shortTime), systemImage: "sparkles")
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                if isGeneratingArticle {
                    ProgressView(NSLocalizedString("detail.wiki.generating", comment: "Generating meeting page"))
                        .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                } else if canGenerateArticle {
                    KnowledgeChipButton(title: NSLocalizedString("detail.wiki.regenerate", comment: "Regenerate page"),
                                        systemImage: "sparkles", action: generate)
                        .accessibilityIdentifier("knowledge.generateNotes")
                }
            } else if isGeneratingArticle {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(NSLocalizedString("detail.wiki.generating", comment: "Generating meeting page"))
                        .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                }
            } else {
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
        }
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

    private func generate() {
        Task {
            if generatesLocally {
                await coordinator.generateLocalMeetingNotes(meeting, wiki: wiki)
            } else {
                await wiki.generate(meeting, trigger: .explicit, force: true)
            }
        }
    }

    @ViewBuilder
    private var contributions: some View {
        switch state {
        case .idle, .loading:
            ProgressView(NSLocalizedString("detail.knowledge.loading", comment: "Loading contributions"))
                .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity).padding(.top, 24)
        case .unavailable:
            ContentUnavailableView(NSLocalizedString("detail.knowledge.unavailable", comment: "Knowledge unavailable"), systemImage: "lock.doc",
                description: Text(NSLocalizedString("detail.knowledge.unavailable_detail", comment: "Access or source data changed")))
        case let .loaded(read):
            if read.contributions.isEmpty {
                ContentUnavailableView(NSLocalizedString("detail.knowledge.empty", comment: "No contributions yet"), systemImage: "book.closed",
                    description: Text(NSLocalizedString("detail.knowledge.empty_detail", comment: "Contributions appear after processing")))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(read.contributions.enumerated()), id: \.element.id) { index, contribution in
                        if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 58).accessibilityHidden(true) }
                        MeetingContributionView(contribution: contribution) { selectedEntityID = contribution.id }
                    }
                }
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

private struct MeetingContributionView: View {
    let contribution: MeetingKnowledgeRead.Contribution
    let onOpenEntity: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onOpenEntity) {
                HStack(spacing: 12) {
                    KnowledgeIconWell(systemImage: "book")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: contribution.name).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                        Text(verbatim: subtitle)
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    KnowledgeChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("knowledge.openEntity")
            if let quote = contribution.entries.first?.fact.source.evidence.first {
                KnowledgeQuote(text: quote.quote)
                    .accessibilityIdentifier("knowledge.quote")
            }
            ForEach(contribution.entries, id: \.fact.id) { entry in
                Divider().overlay(Theme.separator).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: MeetingKnowledgeClaimPresentation.text(entry))
                        .font(Theme.bodyEmphasized).foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("knowledge.claim")
                    HStack(spacing: 6) {
                        Text(NSLocalizedString("knowledge.modality." + entry.fact.qualifiers.modality.rawValue, comment: "Claim modality"))
                        if entry.fact.qualifiers.polarity == .negative {
                            Text(verbatim: "·")
                            Text(NSLocalizedString("detail.knowledge.negated", comment: "Negated claim"))
                        }
                    }
                    .font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
                    ForEach(entry.fact.source.evidence, id: \.id) { evidence in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: evidence.quote)
                                .font(Theme.body).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                                .accessibilityIdentifier("knowledge.quote")
                            Text(String(format: NSLocalizedString("detail.knowledge.attribution", comment: "Claim attribution"), evidence.attributedSpeaker))
                                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.separator).frame(width: 3).accessibilityHidden(true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    /// "<Kind> · +N facts".
    private var subtitle: String {
        let kind = contribution.entries.first.map {
            NSLocalizedString("knowledge.entity_kind." + $0.subject.kind.rawValue, comment: "Entity kind")
        } ?? ""
        return String(format: NSLocalizedString("detail.knowledge.entity_facts", comment: "Kind and new facts"),
                      kind, knowledgeCountText("knowledge.count.fact", contribution.entries.count))
    }
}
