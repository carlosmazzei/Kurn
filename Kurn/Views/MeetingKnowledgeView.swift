import KurnCore
import SwiftUI

struct MeetingKnowledgeView: View {
    let meeting: Meeting
    let state: MeetingKnowledgeState
    let isGeneratingArticle: Bool
    let canGenerateArticle: Bool
    let onRefresh: () -> Void
    @Environment(KnowledgeCompilationCoordinator.self) private var coordinator
    @Environment(WikiCoordinator.self) private var wiki

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if case .loaded = state { articleSection }
                HStack {
                    Text(NSLocalizedString("detail.knowledge.contributions", comment: "Meeting contributions"))
                        .font(Theme.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: onRefresh) {
                        Label(NSLocalizedString("detail.knowledge.refresh", comment: "Refresh contributions"), systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("knowledge.refresh")
                }
                contributions
            }
            .padding(20)
        }
        .accessibilityIdentifier("knowledge.content")
    }

    private var articleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let article = meeting.wikiArticle {
                DisclosureGroup {
                    MeetingWikiContent(article: article).padding(.top, 12)
                } label: {
                    Label(NSLocalizedString("detail.knowledge.notes", comment: "Meeting notes"), systemImage: "book.pages")
                        .font(Theme.headline)
                }
                .accessibilityIdentifier("knowledge.notes")
            } else {
                Text(NSLocalizedString("detail.knowledge.notes", comment: "Meeting notes")).font(Theme.headline)
                Text(NSLocalizedString("detail.knowledge.notes_empty", comment: "Meeting notes description"))
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            }
            if isGeneratingArticle {
                ProgressView(NSLocalizedString("detail.wiki.generating", comment: "Generating meeting notes"))
            } else if canGenerateArticle {
                Button {
                    Task { await coordinator.generateLocalMeetingNotes(meeting, wiki: wiki) }
                } label: {
                    Label(NSLocalizedString(meeting.wikiArticle == nil ? "detail.wiki.generate" : "detail.wiki.regenerate", comment: "Generate notes"),
                        systemImage: "sparkles")
                }
                .accessibilityIdentifier("knowledge.generateNotes")
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var contributions: some View {
        switch state {
        case .idle, .loading:
            ProgressView(NSLocalizedString("detail.knowledge.loading", comment: "Loading contributions"))
        case .unavailable:
            ContentUnavailableView(NSLocalizedString("detail.knowledge.unavailable", comment: "Knowledge unavailable"), systemImage: "lock.doc",
                description: Text(NSLocalizedString("detail.knowledge.unavailable_detail", comment: "Access or source data changed")))
        case let .loaded(read):
            if read.contributions.isEmpty {
                ContentUnavailableView(NSLocalizedString("detail.knowledge.empty", comment: "No contributions yet"), systemImage: "book.closed",
                    description: Text(NSLocalizedString("detail.knowledge.empty_detail", comment: "Contributions appear after processing")))
            } else {
                ForEach(read.contributions) { contribution in
                    MeetingContributionView(contribution: contribution)
                }
            }
        }
    }
}

private struct MeetingContributionView: View {
    let contribution: MeetingKnowledgeRead.Contribution

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: contribution.name)
                .font(Theme.headline)
                .accessibilityAddTraits(.isHeader)
            Text(String(format: NSLocalizedString("detail.knowledge.claim_count", comment: "Claim count"), contribution.entries.count))
                .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            ForEach(contribution.entries, id: \.fact.id) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: MeetingKnowledgeClaimPresentation.text(entry))
                        .font(Theme.bodyEmphasized)
                        .accessibilityIdentifier("knowledge.claim")
                    HStack {
                        Text(NSLocalizedString("knowledge.modality." + entry.fact.qualifiers.modality.rawValue, comment: "Claim modality"))
                        if entry.fact.qualifiers.polarity == .negative {
                            Text(NSLocalizedString("detail.knowledge.negated", comment: "Negated claim"))
                        }
                    }
                    .font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
                    ForEach(entry.fact.source.evidence, id: \.id) { evidence in
                        Text(String(format: NSLocalizedString("detail.knowledge.attribution", comment: "Claim attribution"), evidence.attributedSpeaker))
                            .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                        Text(verbatim: evidence.quote)
                            .font(Theme.body).textSelection(.enabled)
                            .accessibilityIdentifier("knowledge.quote")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}
