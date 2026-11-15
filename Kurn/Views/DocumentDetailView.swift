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
                ReadAloudControl(item: .document(document))

                if document.sourceChatSessionID != nil, let version = document.sourceArtifactVersion {
                    Label(String(format: NSLocalizedString("documents.chat.provenance", comment: "Chat provenance"), version),
                          systemImage: "bubble.left.and.bubble.right")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("documents.chat.provenance")
                }

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
                Menu {
                    ForEach(DocumentExport.formats, id: \.self) { format in
                        Button(format.title) { share(format) }
                    }
                } label: {
                    Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.urls)
        }
        .onDisappear { ReadAloudController.shared.stop(owner: document.id) }
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

    private func share(_ format: MeetingExportFormat) {
        guard let url = try? DocumentExport.file(title: document.title, markdown: document.bodyMarkdown, format: format) else { return }
        shareItem = ShareItem(urls: [url])
    }
}
