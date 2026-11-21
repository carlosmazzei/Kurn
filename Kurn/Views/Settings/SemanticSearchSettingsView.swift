//
//  SemanticSearchSettingsView.swift
//  Kurn
//
//  The on-device semantic index behind meaning-based search and "ask your
//  meetings". Passages and their embeddings live in the SwiftData store, so
//  rebuilding or clearing here is purely local.
//

import SwiftUI

struct SemanticSearchSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SemanticIndexCoordinator.self) private var semanticIndex

    /// Count of indexed passages, refreshed on appear and after a rebuild/clear.
    @State private var semanticChunkCount = 0
    /// True while a rebuild is running, so the buttons show progress and can't
    /// be re-triggered.
    @State private var isRebuildingIndex = false
    /// Drives the confirmation dialog before clearing the local semantic index (G1).
    @State private var showingClearConfirm = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { settings.semanticSearchEnabled },
                        set: { settings.semanticSearchEnabled = $0 }
                    )
                ) {
                    SettingsRowLabel(
                        title: NSLocalizedString("settings.semantic_search", comment: "Semantic search toggle"),
                        detail: NSLocalizedString("settings.semantic_search_footer", comment: "Semantic search footer")
                    )
                }
                LabeledContent(
                    NSLocalizedString("settings.semantic_indexed_passages", comment: "Indexed passages"),
                    value: "\(semanticChunkCount)"
                )
                Button {
                    Task {
                        isRebuildingIndex = true
                        await semanticIndex.rebuild()
                        semanticChunkCount = semanticIndex.indexedChunkCount()
                        isRebuildingIndex = false
                    }
                } label: {
                    if isRebuildingIndex {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("settings.semantic_rebuilding", comment: "Rebuilding index"))
                        }
                    } else {
                        Label(
                            NSLocalizedString("settings.semantic_rebuild", comment: "Rebuild index"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
                .disabled(isRebuildingIndex)
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    Label(
                        NSLocalizedString("settings.semantic_clear", comment: "Clear index"),
                        systemImage: "trash"
                    )
                }
                .disabled(isRebuildingIndex || semanticChunkCount == 0)
                .accessibilityIdentifier("settings.semantic.clear")
            } header: {
                Text(NSLocalizedString("settings.semantic_search_title", comment: "Semantic search section title"))
            }
        }
        .navigationTitle(NSLocalizedString("settings.semantic_search_title", comment: "Semantic search"))
        .task { semanticChunkCount = semanticIndex.indexedChunkCount() }
        .kurnDialog(
            isPresented: $showingClearConfirm,
            iconSystemName: "trash.circle.fill",
            iconTint: Theme.warning,
            title: NSLocalizedString("settings.semantic_clear_confirm.title", comment: "Clear semantic index confirmation"),
            message: NSLocalizedString("settings.semantic_clear_confirm.message", comment: "Clear semantic index message"),
            primaryTitle: NSLocalizedString("settings.semantic_clear", comment: "Clear index"),
            primaryRole: .destructive,
            primaryAction: {
                semanticIndex.clearIndex()
                semanticChunkCount = semanticIndex.indexedChunkCount()
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }
}
