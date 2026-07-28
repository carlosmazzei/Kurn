//
//  DocumentDetailView.swift
//  Kurn
//

import SwiftUI

struct DocumentDetailView: View {
    let document: GeneratedDocument
    @State private var shareItem: ShareItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MarkdownText(document.bodyMarkdown)
                    .textSelection(.enabled)

                Divider()

                DisclosureGroup(NSLocalizedString("documents.details", comment: "Document details")) {
                    VStack(alignment: .leading, spacing: 12) {
                        detailRow(
                            title: NSLocalizedString("documents.prompt.title", comment: "Instructions"),
                            value: document.userPrompt
                        )
                        detailRow(
                            title: document.sourceKind.displayName,
                            value: document.sourceNames.joined(separator: ", ")
                        )
                        detailRow(
                            title: NSLocalizedString("documents.generated_at", comment: "Generated at"),
                            value: document.createdAt.formatted(date: .long, time: .shortened)
                        )
                    }
                    .padding(.top, 12)
                }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { share() } label: {
                    Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.urls)
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
            Text(value)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func share() {
        guard let url = try? MeetingExport.temporaryFile(
            markdown: document.bodyMarkdown,
            suggestedName: document.title
        ) else { return }
        shareItem = ShareItem(urls: [url])
    }
}
