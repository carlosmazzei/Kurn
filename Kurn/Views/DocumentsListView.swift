//
//  DocumentsListView.swift
//  Kurn
//
//  Library of documents generated from selected transcript sources.
//

import SwiftData
import SwiftUI

struct DocumentsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \GeneratedDocument.createdAt, order: .reverse)
    private var documents: [GeneratedDocument]

    @State private var showingCreate = false
    @State private var selectedDocument: GeneratedDocument?
    @State private var pendingDelete: GeneratedDocument?
    @State private var saveError: AppError?

    // This screen carried its own copy of the lock branch, with the same
    // teardown problem as `MeetingsListView`. Authentication is now covered by
    // the window-level `securityCover(…)` in `KurnApp`.
    var body: some View {
        List {
            if documents.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("documents.empty.title", comment: "No documents"),
                    systemImage: "doc.badge.plus",
                    description: Text(NSLocalizedString("documents.empty.subtitle", comment: "Create a document"))
                )
                .clearListRow()
            } else {
                ForEach(documents) { document in
                    Button { selectedDocument = document } label: {
                        documentRow(document)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) { pendingDelete = document } label: {
                            Label(NSLocalizedString("common.delete", comment: "Delete"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(NSLocalizedString("documents.title", comment: "Documents"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCreate = true } label: {
                    Label(NSLocalizedString("documents.new", comment: "New document"), systemImage: "plus")
                }
                .accessibilityIdentifier("documents.new")
            }
        }
        .navigationDestination(item: $selectedDocument) { document in
            DocumentDetailView(document: document)
        }
        .sheet(isPresented: $showingCreate) {
            NavigationStack {
                DocumentCreateView(modelContext: modelContext) { document in
                    selectedDocument = document
                }
            }
        }
        .kurnDialog(
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("documents.delete.confirm", comment: "Delete document"),
            message: pendingDelete?.title ?? "",
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                if let document = pendingDelete {
                    modelContext.delete(document)
                    saveError = modelContext.saveOrError()
                }
                pendingDelete = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: { pendingDelete = nil }
        )
        .errorAlert($saveError)
    }

    private func documentRow(_ document: GeneratedDocument) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "doc.text.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: document.sourceKind.systemImage)
                        .accessibilityHidden(true)
                    Text(document.sourceNames.joined(separator: ", "))
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                Text(document.createdAt.meetingDisplay)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
