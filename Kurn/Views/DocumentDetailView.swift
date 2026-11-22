//
//  DocumentDetailView.swift
//  Kurn
//

import KurnCore
import SwiftData
import SwiftUI

struct DocumentDetailView: View {
    let document: GeneratedDocument

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?
    @State private var showingSource = false
    @State private var showingDeleteConfirm = false
    @State private var saveError: AppError?

    private var readAloudItem: ReadAloudItem { .document(document) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(metaLine)
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.textSecondary)

                ReadAloudControl(item: readAloudItem, ghost: true)

                MarkdownText(document.bodyMarkdown)
                    .textSelection(.enabled)
            }
            .padding(20)
        }
        .background(Theme.readingBackground.ignoresSafeArea())
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .bottom) {
            if ReadAloudController.shared.phase(for: readAloudItem.id) != .idle {
                ReadAloudBar(
                    item: readAloudItem,
                    title: NSLocalizedString("documents.read_aloud.title", comment: "Reading the document")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(DocumentExport.formats, id: \.self) { format in
                        Button(format.title) { share(format) }
                    }
                } label: {
                    Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel(NSLocalizedString("detail.share", comment: "Share"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        MeetingPasteboard.copy(document.bodyMarkdown)
                    } label: {
                        Label(
                            NSLocalizedString("documents.copy_markdown", comment: "Copy Markdown"),
                            systemImage: "doc.on.doc"
                        )
                    }
                    ForEach(DocumentExport.formats, id: \.self) { format in
                        Button {
                            share(format)
                        } label: {
                            Label(exportTitle(format), systemImage: "arrow.up.doc")
                        }
                    }
                    Divider()
                    Button { showingSource = true } label: {
                        Label(
                            NSLocalizedString("documents.provenance", comment: "Where it came from"),
                            systemImage: "info.circle"
                        )
                    }
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label(
                            NSLocalizedString("documents.delete", comment: "Delete document"),
                            systemImage: "trash"
                        )
                    }
                } label: {
                    Label(
                        NSLocalizedString("documents.actions", comment: "Document actions"),
                        systemImage: "ellipsis.circle"
                    )
                }
                .accessibilityLabel(NSLocalizedString("documents.actions", comment: "Document actions"))
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.urls)
        }
        .sheet(isPresented: $showingSource) {
            NavigationStack {
                List {
                    if document.sourceChatSessionID != nil, let version = document.sourceArtifactVersion {
                        Label(
                            String(
                                format: NSLocalizedString("documents.chat.provenance", comment: "Chat provenance"),
                                version
                            ),
                            systemImage: "bubble.left.and.bubble.right"
                        )
                        .accessibilityIdentifier("documents.chat.provenance")
                    }
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
                .navigationTitle(NSLocalizedString("documents.provenance", comment: "Where it came from"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("common.done", comment: "Done")) { showingSource = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .kurnDialog(
            isPresented: $showingDeleteConfirm,
            iconSystemName: "trash.fill",
            iconTint: Theme.destructive,
            title: NSLocalizedString("documents.delete.confirm", comment: "Delete document"),
            message: NSLocalizedString("documents.delete.message", comment: "The conversation is kept"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: { deleteDocument() },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .errorAlert($saveError)
        .onDisappear { ReadAloudController.shared.stop(owner: document.id) }
    }

    /// "Created <relative day> <time> · <model> · version N" — each part omitted
    /// when the document carries no value for it.
    private var metaLine: String {
        var parts = [
            String(
                format: NSLocalizedString("documents.meta.created", comment: "Created at"),
                document.createdAt.relativeDay,
                document.createdAt.shortTime
            )
        ]
        if !document.generatorModelIdentifier.isEmpty {
            parts.append(document.generatorModelIdentifier)
        }
        if let version = document.sourceArtifactVersion {
            parts.append(String(
                format: NSLocalizedString("documents.meta.version", comment: "Document version"),
                version
            ))
        }
        return parts.joined(separator: " · ")
    }

    private func exportTitle(_ format: MeetingExportFormat) -> String {
        switch format {
        case .standard:
            NSLocalizedString("documents.export.markdown", comment: "Export Markdown")
        case .docx:
            NSLocalizedString("documents.export.word", comment: "Export Word")
        case .html:
            NSLocalizedString("documents.export.html", comment: "Export HTML")
        default:
            format.title
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

    private func share(_ format: MeetingExportFormat) {
        guard let url = try? DocumentExport.file(title: document.title, markdown: document.bodyMarkdown, format: format) else { return }
        shareItem = ShareItem(urls: [url])
    }

    private func deleteDocument() {
        do throws(AppError) {
            try MeetingLibrary(context: modelContext).deleteDocument(document)
        } catch {
            saveError = error
            return
        }
        dismiss()
    }
}
