import SwiftUI

struct KnowledgeIdentityReviewView: View {
    let candidate: KnowledgeReviewRead.Candidate
    let allowsMutation: Bool
    let decide: (KnowledgeReviewCommand) -> Void
    @State private var confirming = false

    var body: some View {
        List {
            Section(KnowledgeReviewCopy.text("combine")) {
                Text(verbatim: candidate.source.name).font(.headline)
                ForEach(candidate.source.aliases, id: \.self) { Text(verbatim: $0) }
            }
            Section(KnowledgeReviewCopy.text("keep")) {
                Text(verbatim: candidate.target.name).font(.headline)
                ForEach(candidate.target.aliases, id: \.self) { Text(verbatim: $0) }
            }
            Section {
                Text(KnowledgeReviewCopy.text("merge_detail"))
                if candidate.isDismissed {
                    Button(KnowledgeReviewCopy.text("reopen")) { decide(.reopen(candidate.id)) }
                        .accessibilityIdentifier("knowledge.review.reopen")
                } else {
                    Button(KnowledgeReviewCopy.text("merge")) { confirming = true }
                        .accessibilityIdentifier("knowledge.review.merge")
                    Button(KnowledgeReviewCopy.text("dismiss")) { decide(.dismiss(candidate.id)) }
                        .accessibilityIdentifier("knowledge.review.dismiss")
                }
            }
            .disabled(!allowsMutation)
        }
        .navigationTitle(KnowledgeReviewCopy.text("possible_match"))
        .alert(KnowledgeReviewCopy.text("confirm_title"), isPresented: $confirming) {
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
            Button(KnowledgeReviewCopy.text("merge")) { decide(.merge(candidate.id)) }
                .accessibilityIdentifier("knowledge.review.confirmMerge")
        } message: {
            Text(String(format: KnowledgeReviewCopy.text("confirm_detail"), candidate.target.name))
        }
    }
}
