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

    var body: some View {
        Form {
            Section {
                Toggle(
                    NSLocalizedString("settings.semantic_search", comment: "Semantic search toggle"),
                    isOn: Binding(
                        get: { settings.semanticSearchEnabled },
                        set: { settings.semanticSearchEnabled = $0 }
                    )
                )
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
                    semanticIndex.clearIndex()
                    semanticChunkCount = semanticIndex.indexedChunkCount()
                } label: {
                    Label(
                        NSLocalizedString("settings.semantic_clear", comment: "Clear index"),
                        systemImage: "trash"
                    )
                }
                .disabled(isRebuildingIndex || semanticChunkCount == 0)
            } header: {
                Text(NSLocalizedString("settings.semantic_search_title", comment: "Semantic search section title"))
            } footer: {
                Text(NSLocalizedString("settings.semantic_search_footer", comment: "Semantic search footer"))
            }
        }
        .navigationTitle(NSLocalizedString("settings.semantic_search_title", comment: "Semantic search"))
        .task { semanticChunkCount = semanticIndex.indexedChunkCount() }
    }
}
