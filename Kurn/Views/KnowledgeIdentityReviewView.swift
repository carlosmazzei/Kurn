import SwiftUI

struct KnowledgeIdentityReviewView: View {
    let candidate: KnowledgeReviewRead.Candidate
    let allowsMutation: Bool
    let decide: (KnowledgeReviewCommand) -> Void
    @State private var confirming = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                identity(KnowledgeReviewCopy.text("combine"), name: candidate.source.name, aliases: candidate.source.aliases)
                identity(KnowledgeReviewCopy.text("keep"), name: candidate.target.name, aliases: candidate.target.aliases)
                Text(KnowledgeReviewCopy.text("merge_detail"))
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                actions.disabled(!allowsMutation).padding(.top, 8)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
        .knowledgeReadingSurface()
        .navigationTitle(KnowledgeReviewCopy.text("possible_match"))
        .navigationBarTitleDisplayMode(.inline)
        .kurnDialog(
            isPresented: $confirming,
            iconSystemName: "arrow.triangle.merge",
            iconTint: Theme.accent,
            title: KnowledgeReviewCopy.text("confirm_title"),
            message: String(format: KnowledgeReviewCopy.text("confirm_detail"), candidate.target.name),
            primaryTitle: KnowledgeReviewCopy.text("merge"),
            primaryAction: { decide(.merge(candidate.id)) },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    private func identity(_ title: String, name: String, aliases: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            KnowledgeSectionLabel(title)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: name).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                if !aliases.isEmpty {
                    Text(verbatim: aliases.joined(separator: " · ")).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .knowledgeCard()
        }
    }

    /// Merging is the decision this screen exists for; keeping the two apart
    /// or reviewing again is the secondary one (Theme "Button language").
    @ViewBuilder
    private var actions: some View {
        if candidate.isDismissed {
            Button { decide(.reopen(candidate.id)) } label: {
                Text(KnowledgeReviewCopy.text("reopen")).font(Theme.calloutEmphasized).frame(maxWidth: .infinity).frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("knowledge.review.reopen")
        } else {
            VStack(spacing: 10) {
                Button { confirming = true } label: {
                    Text(KnowledgeReviewCopy.text("merge")).font(Theme.calloutEmphasized).frame(maxWidth: .infinity).frame(minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .accessibilityIdentifier("knowledge.review.merge")
                Button { decide(.dismiss(candidate.id)) } label: {
                    Text(KnowledgeReviewCopy.text("dismiss")).font(Theme.calloutEmphasized).frame(maxWidth: .infinity).frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("knowledge.review.dismiss")
            }
        }
    }
}
