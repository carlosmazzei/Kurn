//
//  DocumentsListView.swift
//  Kurn
//
//  Library of documents generated from selected transcript sources.
//

import SwiftData
import KurnCore
import SwiftUI

struct DocumentsListView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GeneratedDocument.createdAt, order: .reverse)
    private var documents: [GeneratedDocument]

    @State private var showingCreate = false
    @State private var showingProviderSettings = false
    @State private var searchText = ""
    @State private var selectedDocument: GeneratedDocument?
    @State private var pendingDelete: GeneratedDocument?
    @State private var saveError: AppError?

    private var filteredDocuments: [GeneratedDocument] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return documents }
        return documents.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.sourceNames.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    // This screen carried its own copy of the lock branch, with the same
    // teardown problem as `MeetingsListView`. Authentication is now covered by
    // the window-level `securityCover(…)` in `KurnApp`.
    var body: some View {
        List {
            if documents.isEmpty {
                // One empty state, the same shape the Summary and Wiki tabs
                // use — with an agent-capable provider it offers Ask and the
                // writer footnote; without one it offers provider setup with
                // the reason instead of a second stacked empty state.
                if settings.aiProvider.kind.supportsAgentChat {
                    MeetingGenerateEmptyState(
                        systemImage: "doc.text",
                        title: NSLocalizedString("documents.empty.title", comment: "No documents"),
                        description: NSLocalizedString("documents.empty.subtitle", comment: "Create a document"),
                        actionTitle: NSLocalizedString("documents.ask", comment: "Ask for a document"),
                        actionIdentifier: "documents.new",
                        footnote: MeetingGenerateEmptyState.modelNudge(
                            provider: settings.aiProvider,
                            model: settings.summaryModel(for: settings.aiProvider)
                        ),
                        action: { showingCreate = true }
                    )
                    .clearListRow()
                } else {
                    MeetingGenerateEmptyState(
                        systemImage: "doc.text",
                        title: NSLocalizedString("documents.empty.title", comment: "No documents"),
                        description: NSLocalizedString("documents.empty.subtitle", comment: "Create a document"),
                        actionTitle: NSLocalizedString("chat.provider.setup", comment: "Set up provider"),
                        actionIdentifier: "chat.artifact.provider.settings",
                        footnote: NSLocalizedString("documents.needs_provider", comment: "Provider cannot create documents"),
                        action: { showingProviderSettings = true }
                    )
                    .clearListRow()
                }
            } else {
                ForEach(filteredDocuments) { document in
                    Button { selectedDocument = document } label: {
                        documentRow(document)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("documents.open")
                    .swipeActions {
                        Button(role: .destructive) { pendingDelete = document } label: {
                            Label(NSLocalizedString("common.delete", comment: "Delete"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .searchable(
            text: $searchText,
            prompt: NSLocalizedString("documents.search", comment: "Search documents")
        )
        .navigationTitle(NSLocalizedString("documents.title", comment: "Documents"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCreate = true } label: {
                    Label(NSLocalizedString("documents.new", comment: "New document"), systemImage: "plus")
                }
                .accessibilityIdentifier("documents.new")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !documents.isEmpty {
                Text(NSLocalizedString("documents.footer", comment: "How documents are made"))
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    // Same 20pt side margins as the list's inset groups.
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, 6)
            }
        }
        .navigationDestination(item: $selectedDocument) { document in
            DocumentDetailView(document: document)
        }
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                MeetingChatView(
                    meeting: nil,
                    initialScope: ChatSourceScope(kind: .library),
                    initialDraft: NSLocalizedString("documents.new_draft", comment: "Draft prompt for a new document")
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("common.done", comment: "Done")) { showingCreate = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showingProviderSettings) {
            NavigationStack {
                ProvidersSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("common.done", comment: "Done")) {
                                showingProviderSettings = false
                            }
                        }
                    }
            }
        }
        .kurnDialog(
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.destructive,
            title: NSLocalizedString("documents.delete.confirm", comment: "Delete document"),
            message: NSLocalizedString("documents.delete.message", comment: "The conversation is kept"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                if let document = pendingDelete {
                    do throws(AppError) {
                        try MeetingLibrary(context: modelContext).deleteDocument(document)
                    } catch {
                        saveError = error
                    }
                }
                pendingDelete = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: { pendingDelete = nil }
        )
        .errorAlert($saveError)
    }

    private func documentRow(_ document: GeneratedDocument) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(documentSubtitle(document))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
    }

    /// "From: <meeting title or N meetings> · <relative day>".
    private func documentSubtitle(_ document: GeneratedDocument) -> String {
        let source = document.sourceNames.count == 1
            ? document.sourceNames[0]
            : String(
                format: NSLocalizedString("documents.sources_count", comment: "N source meetings"),
                document.sourceNames.count
            )
        return String(
            format: NSLocalizedString("documents.row.subtitle", comment: "From: source · day"),
            source,
            document.createdAt.relativeDay
        )
    }
}
