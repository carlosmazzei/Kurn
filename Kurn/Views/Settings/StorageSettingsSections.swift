//
//  StorageSettingsSections.swift
//  Kurn
//
//  The two storage sections that need `RecordingCompactionViewModel`: the one-shot
//  recording compaction, and the breakdown of which meetings are using the space.
//  Split out of `StorageSettingsView` to keep that file inside SwiftLint's length
//  budget; it is an extension, so the state it reads is non-private there.
//

import SwiftUI

extension StorageSettingsView {
    /// One-shot re-encode of already-transcribed recordings down to the current
    /// quality setting. Hidden entirely when there is nothing to gain, so the
    /// screen doesn't offer a destructive action that would do nothing.
    @ViewBuilder
    var compactionSection: some View {
        if let compaction, compaction.candidateCount > 0 || compaction.isRunning {
            Section {
                if compaction.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: compaction.progress ?? 0)
                        HStack {
                            Text(NSLocalizedString("settings.compact.running", comment: "Compacting recordings"))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Button(NSLocalizedString("common.cancel", comment: "Cancel")) {
                                compaction.cancel()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } else {
                    Button {
                        showingCompactConfirm = true
                    } label: {
                        HStack {
                            Label(
                                NSLocalizedString("settings.compact", comment: "Compact recordings"),
                                systemImage: "arrow.down.circle"
                            )
                            Spacer()
                            Text(
                                String(
                                    format: NSLocalizedString("settings.compact.preview", comment: "Reclaimable audio space"),
                                    AudioFileStore.formattedSize(compaction.estimatedSavings)
                                )
                            )
                            .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("settings.compact.section", comment: "Reclaim audio space"))
            } footer: {
                Text(NSLocalizedString("settings.compact_footer", comment: "Explains what compaction does"))
            }
        }
    }

    /// Originals `RecordingQuarantine` preserved instead of deleting: the user
    /// can put one back into the library, export the raw file, or confirm its
    /// deletion. Hidden entirely while the quarantine is empty.
    @ViewBuilder
    var quarantineSection: some View {
        if !quarantineItems.isEmpty {
            Section {
                ForEach(quarantineItems) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.quarantinedAt, format: .dateTime.year().month().day().hour().minute())
                                .lineLimit(1)
                            Text(item.reason.localizedDescription)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(AudioFileStore.formattedSize(item.byteSize))
                            .foregroundStyle(Theme.textSecondary)
                        Button {
                            recoverQuarantined(item)
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(NSLocalizedString("quarantine.recover", comment: "Recover recording"))
                        Button {
                            exportQuarantined(item)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(NSLocalizedString("quarantine.export", comment: "Export recording"))
                        Button {
                            pendingQuarantineDeletion = item
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .tint(.red)
                        .accessibilityLabel(NSLocalizedString("quarantine.delete", comment: "Delete recording"))
                    }
                }
            } header: {
                Text(NSLocalizedString("quarantine.section", comment: "Preserved recordings"))
            } footer: {
                Text(NSLocalizedString("quarantine.footer", comment: "Explains the quarantine"))
            }
        }
    }

    /// Which meetings the audio actually belongs to, so the user can delete the
    /// outliers themselves. Informational only — deletion stays in the library,
    /// where the meeting's transcript and summary are visible alongside it.
    @ViewBuilder
    var largestMeetingsSection: some View {
        if let compaction, !compaction.largestMeetings.isEmpty {
            Section {
                ForEach(compaction.largestMeetings) { usage in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(usage.title)
                                .lineLimit(1)
                            Text(usage.duration.clockDisplay)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(AudioFileStore.formattedSize(usage.bytes))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            } header: {
                Text(NSLocalizedString("settings.largest_recordings", comment: "Largest recordings"))
            } footer: {
                Text(NSLocalizedString("settings.largest_recordings_footer", comment: "Explains the breakdown"))
            }
        }
    }
}
