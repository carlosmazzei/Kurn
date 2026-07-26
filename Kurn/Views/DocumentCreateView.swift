//
//  DocumentCreateView.swift
//  Kurn
//
//  Source picker and prompt composer for a generated document.
//

import SwiftData
import SwiftUI

struct DocumentCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \Folder.name) private var folders: [Folder]

    @State private var sourceKind = DocumentSourceKind.transcripts
    @State private var selectedIDs: Set<UUID> = []
    @State private var prompt = ""
    @State private var viewModel: DocumentGenerationViewModel

    let onCreated: (GeneratedDocument) -> Void

    init(modelContext: ModelContext, onCreated: @escaping (GeneratedDocument) -> Void) {
        _viewModel = State(initialValue: DocumentGenerationViewModel(modelContext: modelContext))
        self.onCreated = onCreated
    }

    private var transcribedMeetings: [Meeting] {
        meetings.filter(\.hasAnyTranscript)
    }

    private var resolvedSources: ResolvedDocumentSources {
        DocumentSourceResolver.resolve(
            kind: sourceKind,
            selectedIDs: selectedIDs,
            meetings: meetings,
            tags: tags,
            folders: folders
        )
    }

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !resolvedSources.meetings.isEmpty
            && !viewModel.isGenerating
    }

    var body: some View {
        Form {
            Section(NSLocalizedString("documents.prompt.title", comment: "Document instructions")) {
                TextEditor(text: $prompt)
                    .frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text(NSLocalizedString("documents.prompt.placeholder", comment: "Prompt placeholder"))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }

            Section {
                Picker(
                    NSLocalizedString("documents.source.title", comment: "Source type"),
                    selection: $sourceKind
                ) {
                    ForEach(DocumentSourceKind.allCases) { kind in
                        Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: sourceKind) { _, _ in selectedIDs.removeAll() }

                sourceRows
            } header: {
                Text(NSLocalizedString("documents.source.title", comment: "Sources"))
            } footer: {
                if !selectedIDs.isEmpty {
                    Text(
                        String(
                            format: NSLocalizedString(
                                "documents.source.count",
                                comment: "Number of transcripts included"
                            ),
                            resolvedSources.meetings.count
                        )
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("documents.new", comment: "New document"))
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(viewModel.isGenerating)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                    .disabled(viewModel.isGenerating)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await generate() }
                } label: {
                    if viewModel.isGenerating {
                        ProgressView()
                    } else {
                        Text(NSLocalizedString("documents.generate", comment: "Generate"))
                    }
                }
                .disabled(!canGenerate)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let progress = viewModel.progress {
                Text(
                    String(
                        format: NSLocalizedString("documents.generating.progress", comment: "Generation progress"),
                        progress.current,
                        progress.total
                    )
                )
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .errorAlert($viewModel.error)
    }

    @ViewBuilder
    private var sourceRows: some View {
        switch sourceKind {
        case .transcripts:
            if transcribedMeetings.isEmpty {
                emptySources
            } else {
                ForEach(transcribedMeetings) { meeting in
                    selectionRow(
                        id: meeting.id,
                        title: meeting.title,
                        subtitle: meeting.createdAt.meetingDisplay,
                        icon: "text.quote"
                    )
                }
            }
        case .tags:
            if tags.isEmpty {
                emptySources
            } else {
                ForEach(tags) { tag in
                    selectionRow(
                        id: tag.id,
                        title: tag.name,
                        subtitle: String(
                            format: NSLocalizedString("documents.source.count", comment: "Transcript count"),
                            tag.meetings.filter(\.hasAnyTranscript).count
                        ),
                        icon: "tag.fill"
                    )
                }
            }
        case .folders:
            if folders.isEmpty {
                emptySources
            } else {
                ForEach(folders) { folder in
                    selectionRow(
                        id: folder.id,
                        title: folder.name,
                        subtitle: String(
                            format: NSLocalizedString("documents.source.count", comment: "Transcript count"),
                            DocumentSourceResolver.transcriptCount(
                                in: folder,
                                meetings: meetings,
                                folders: folders
                            )
                        ),
                        icon: folder.iconName
                    )
                }
            }
        }
    }

    private var emptySources: some View {
        ContentUnavailableView(
            NSLocalizedString("documents.source.empty", comment: "No sources"),
            systemImage: sourceKind.systemImage,
            description: Text(NSLocalizedString("documents.source.empty.subtitle", comment: "No transcribed sources"))
        )
    }

    private func selectionRow(
        id: UUID,
        title: String,
        subtitle: String,
        icon: String
    ) -> some View {
        Button {
            if !selectedIDs.insert(id).inserted {
                selectedIDs.remove(id)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Theme.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: selectedIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedIDs.contains(id) ? Theme.accent : Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func generate() async {
        let document = await viewModel.generate(
            meetings: resolvedSources.meetings,
            prompt: prompt,
            sourceKind: sourceKind,
            sourceNames: resolvedSources.sourceNames,
            settings: settings
        )
        guard let document else { return }
        onCreated(document)
        dismiss()
    }
}
