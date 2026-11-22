import KurnCore
import SwiftUI

struct MeetingKnowledgeView: View {
    let meeting: Meeting
    let state: MeetingKnowledgeState
    let isGeneratingArticle: Bool
    let canGenerateArticle: Bool
    /// Apple on-device generation revalidates the canonical read first; another provider uses the
    /// same explicit wiki generation the summary and transcript tabs' siblings use.
    let generatesLocally: Bool
    let onRefresh: () -> Void
    @Environment(KnowledgeCompilationCoordinator.self) private var coordinator
    @Environment(WikiCoordinator.self) private var wiki
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedEntityID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if case .loaded = state { articleSection }
                contributionsHeader
                contributions
            }
            // The same insets as the Transcript and Summary tabs.
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
        .accessibilityIdentifier("knowledge.content")
        .sheet(isPresented: Binding(get: { selectedEntityID != nil }, set: { if !$0 { selectedEntityID = nil } })) {
            if let selectedEntityID { KnowledgeBrowserView(meetingIDs: [meeting.id], initialEntityID: selectedEntityID) }
        }
    }

    /// The section label with the refresh chip beside it, or under it at
    /// accessibility text sizes.
    @ViewBuilder
    private var contributionsHeader: some View {
        let label = KnowledgeSectionLabel(NSLocalizedString("detail.knowledge.contributions", comment: "Meeting contributions"))
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                label
                refreshButton
            }
        } else {
            HStack {
                label
                Spacer()
                refreshButton
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
                DisclosureGroup {
                    MeetingWikiContent(article: article).padding(.top, 12)
                } label: {
                    notesTitle
                }
                .tint(Theme.textSecondary)
                .accessibilityIdentifier("knowledge.notes")
            } else {
                notesTitle
                Text(NSLocalizedString("detail.knowledge.notes_empty", comment: "Meeting notes description"))
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isGeneratingArticle {
                ProgressView(NSLocalizedString("detail.wiki.generating", comment: "Generating meeting notes"))
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            } else if canGenerateArticle {
                KnowledgeChipButton(title: NSLocalizedString(meeting.wikiArticle == nil ? "detail.wiki.generate" : "detail.wiki.regenerate",
                                                             comment: "Generate notes"),
                                    systemImage: "sparkles") {
                    Task {
                        if generatesLocally {
                            await coordinator.generateLocalMeetingNotes(meeting, wiki: wiki)
                        } else {
                            await wiki.generate(meeting, trigger: .explicit, force: true)
                        }
                    }
                }
                .accessibilityIdentifier("knowledge.generateNotes")
            }
        }
        .knowledgeCard()
    }

    private var notesTitle: some View {
        HStack(spacing: 12) {
            KnowledgeIconWell(systemImage: "book.pages")
            Text(NSLocalizedString("detail.knowledge.notes", comment: "Meeting notes"))
                .font(Theme.headline).foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
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
                ForEach(read.contributions) { contribution in
                    MeetingContributionView(contribution: contribution) { selectedEntityID = contribution.id }
                }
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
                    KnowledgeIconWell(systemImage: "book.pages")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: contribution.name).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                        Text(String(format: NSLocalizedString("detail.knowledge.claim_count", comment: "Claim count"), contribution.entries.count))
                            .font(Theme.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    KnowledgeChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("knowledge.openEntity")
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
        .knowledgeCard()
    }
}
