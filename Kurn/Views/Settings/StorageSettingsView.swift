//
//  StorageSettingsView.swift
//  Kurn
//
//  What Kurn is using on disk: recorded audio (with the largest meetings called
//  out), reclaimable temp files, the one-shot recording compaction, and the
//  downloaded FluidAudio model groups. Deleting a model group frees its space
//  and turns the matching feature off so it can be re-downloaded on demand.
//
//  The compaction and largest-meetings sections live in
//  `StorageSettingsSections.swift` as an extension, so several members here are
//  non-private — an extension in another file cannot see `private` ones.
//

import SwiftData
import SwiftUI

struct StorageSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadController.self) private var downloads
    @Environment(\.modelContext) private var modelContext

    @State private var storageText = "—"
    /// Free space on the volume, for context next to what Kurn is using.
    @State private var freeSpaceText = "—"
    /// Current estimate of temp files that can be removed by the manual cleanup.
    @State private var cacheCleanupPreview: (files: Int, bytes: Int64) = (0, 0)
    /// Result of the temp-file cleanup (files count + bytes) to show in an alert.
    @State private var cacheCleanupResult: (files: Int, bytes: Int64)?
    @State private var showingClearCacheConfirm = false
    /// Created lazily in `.task` because it needs the environment's model context.
    @State var compaction: RecordingCompactionViewModel?
    @State var showingCompactConfirm = false

    var body: some View {
        Form {
            Section(NSLocalizedString("settings.storage", comment: "Storage")) {
                LabeledContent(
                    NSLocalizedString("settings.audio_usage", comment: "Audio usage"),
                    value: storageText
                )
                LabeledContent(
                    NSLocalizedString("settings.free_space", comment: "Free space"),
                    value: freeSpaceText
                )
                Button {
                    Task { @MainActor in
                        cacheCleanupPreview = await loadCacheCleanupPreview()
                        showingClearCacheConfirm = true
                    }
                } label: {
                    HStack {
                        Label(
                            NSLocalizedString("settings.clear_cache", comment: "Clear temporary files"),
                            systemImage: "trash"
                        )
                        Spacer()
                        Text(
                            String(
                                format: NSLocalizedString("settings.clear_cache.preview", comment: "Reclaimable temp space"),
                                AudioFileStore.formattedSize(cacheCleanupPreview.bytes)
                            )
                        )
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            compactionSection
            largestMeetingsSection
            modelsSection
        }
        .navigationTitle(NSLocalizedString("settings.storage", comment: "Storage"))
        .task {
            if compaction == nil {
                compaction = RecordingCompactionViewModel(modelContext: modelContext)
            }
            compaction?.refresh(targetBitRate: settings.audioQuality.bitRate)
            refreshStorage()
            cacheCleanupPreview = await loadCacheCleanupPreview()
            downloads.refreshInstalledModels()
        }
        .errorAlert(Binding(
            get: { compaction?.error },
            set: { compaction?.error = $0 }
        ))
        .kurnDialog(
            isPresented: $showingCompactConfirm,
            iconSystemName: "arrow.down.circle.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.compact.confirm", comment: "Compact recordings"),
            message: String(
                format: NSLocalizedString("settings.compact.message", comment: "Compaction is irreversible"),
                compaction?.candidateCount ?? 0,
                AudioFileStore.formattedSize(compaction?.estimatedSavings ?? 0)
            ),
            primaryTitle: NSLocalizedString("settings.compact", comment: "Compact recordings"),
            primaryRole: .destructive,
            primaryAction: {
                compaction?.start(targetBitRate: settings.audioQuality.bitRate)
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: Binding(
                get: { compaction?.completedSavings != nil },
                set: { if !$0 { compaction?.completedSavings = nil } }
            ),
            iconSystemName: "checkmark.circle.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.compact.done", comment: "Recordings compacted"),
            message: String(
                format: NSLocalizedString("settings.compact.result", comment: "Compaction result"),
                AudioFileStore.formattedSize(compaction?.completedSavings ?? 0)
            ),
            primaryTitle: NSLocalizedString("common.ok", comment: "OK"),
            primaryAction: { refreshStorage() }
        )
        .kurnDialog(
            isPresented: Binding(
                get: { downloads.pendingModelDeletion != nil },
                set: { if !$0 { downloads.pendingModelDeletion = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.models.delete_confirm", comment: "Confirm delete model"),
            message: NSLocalizedString("settings.models.delete_message", comment: "Re-download later"),
            primaryTitle: NSLocalizedString("settings.models.delete", comment: "Delete model"),
            primaryRole: .destructive,
            primaryAction: {
                if let model = downloads.pendingModelDeletion {
                    downloads.deleteModel(model, settings: settings)
                }
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: Binding(
                get: { cacheCleanupResult != nil },
                set: { if !$0 { cacheCleanupResult = nil } }
            ),
            iconSystemName: "checkmark.circle.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.clear_cache.done", comment: "Temporary files cleared"),
            message: cacheCleanupResult.map { result in
                String(
                    format: NSLocalizedString("settings.clear_cache.result", comment: "Cache cleared result"),
                    result.files,
                    AudioFileStore.formattedSize(result.bytes)
                )
            } ?? "",
            primaryTitle: NSLocalizedString("common.ok", comment: "OK"),
            primaryAction: {}
        )
        .kurnDialog(
            isPresented: $showingClearCacheConfirm,
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.clear_cache.confirm", comment: "Clear temporary files"),
            message: String(
                format: NSLocalizedString("settings.clear_cache.message", comment: "Clear cache message"),
                cacheCleanupPreview.files,
                AudioFileStore.formattedSize(cacheCleanupPreview.bytes)
            ),
            primaryTitle: NSLocalizedString("settings.clear_cache", comment: "Clear temporary files"),
            primaryRole: .destructive,
            primaryAction: {
                Task {
                    let result = await Task.detached(priority: .utility) {
                        TempFileCleaner.forceCleanup()
                    }.value
                    cacheCleanupResult = result
                    refreshStorage()
                    cacheCleanupPreview = await loadCacheCleanupPreview()
                }
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    /// Downloaded on-device models the user can inspect and remove. Only groups
    /// actually present on disk are listed; unassociated FluidAudio folders show
    /// up as a separate entry.
    @ViewBuilder
    private var modelsSection: some View {
        Section {
            if downloads.installedModels.isEmpty {
                Text(NSLocalizedString("settings.models.none", comment: "No models downloaded"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(downloads.installedModels) { model in
                    HStack {
                        Text(model.displayName)
                        Spacer()
                        Text(AudioFileStore.formattedSize(model.size))
                            .foregroundStyle(Theme.textSecondary)
                        Button {
                            downloads.pendingModelDeletion = model
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .tint(.red)
                        .disabled(downloads.isDownloading)
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("settings.models", comment: "On-device models"))
        } footer: {
            Text(NSLocalizedString("settings.models_footer", comment: "Models footer"))
        }
    }

    func refreshStorage() {
        storageText = AudioFileStore.formattedSize(AudioFileStore.totalAudioBytes())
        freeSpaceText = AudioFileStore.formattedSize(ResourceGuard.availableStorageBytes() ?? 0)
    }

    private func loadCacheCleanupPreview() async -> (files: Int, bytes: Int64) {
        await Task.detached(priority: .utility) {
            TempFileCleaner.reclaimableSpace()
        }.value
    }
}
