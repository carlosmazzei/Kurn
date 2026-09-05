//
//  HealthRecoveryView+Sections.swift
//  Kurn
//
//  The six aggregated sections, split out of HealthRecoveryView.swift to keep
//  that file under SwiftLint's type-body-length warning as this grows.
//

import SwiftUI
import KurnCore

extension HealthRecoveryView {
    @ViewBuilder
    var recoverySection: some View {
        if !recoveryNeeded.isEmpty {
            Section {
                ForEach(recoveryNeeded) { recording in
                    HStack {
                        // Two independent sibling `Button`s, not a row-level
                        // tap gesture with a button nested inside it — the
                        // latter risks the outer gesture swallowing the
                        // inner button's own taps in a `List`.
                        Button {
                            openMeeting(for: recording)
                        } label: {
                            rowLabel(
                                title: meetingTitle(for: recording),
                                subtitle: recording.recordedAt.meetingDisplay,
                                systemImage: "exclamationmark.triangle.fill",
                                tint: .red
                            )
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            retryCaptureRecovery(recording)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text(NSLocalizedString("health.recovery_needed", comment: "Pending recovery"))
            } footer: {
                Text(NSLocalizedString("health.recovery_needed_footer", comment: "Explains pending recovery"))
            }
        }
    }

    @ViewBuilder
    var stalledSection: some View {
        if !stalledTranscriptions.isEmpty {
            Section {
                ForEach(stalledTranscriptions) { recording in
                    HStack {
                        Button {
                            openMeeting(for: recording)
                        } label: {
                            rowLabel(
                                title: meetingTitle(for: recording),
                                subtitle: recording.transcriptionStatus.displayName,
                                systemImage: "waveform.badge.exclamationmark",
                                tint: Theme.warning
                            )
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            retryTranscription(recording)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(txVM?.isTranscribing(recording) == true)
                    }
                }
            } header: {
                Text(NSLocalizedString("health.stalled_transcriptions", comment: "Failed or deferred transcriptions"))
            } footer: {
                Text(NSLocalizedString("health.stalled_transcriptions_footer", comment: "Explains failed/deferred jobs"))
            }
        }
    }

    @ViewBuilder
    var degradedSection: some View {
        if !degraded.isEmpty {
            Section {
                ForEach(degraded) { item in
                    HStack {
                        Button {
                            openMeeting(for: item.recording)
                        } label: {
                            rowLabel(
                                title: meetingTitle(for: item.recording),
                                subtitle: HealthRecoveryAggregation.degradedSubtitle(for: item.report),
                                systemImage: "exclamationmark.triangle.fill",
                                tint: Theme.warning
                            )
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if HealthRecoveryAggregation.canRetryCorrection(item.report) {
                            Button {
                                retryCorrection(item.recording)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .disabled(txVM?.correctionRetryIDs.contains(item.recording.id) == true)
                        }
                    }
                }
            } header: {
                Text(NSLocalizedString("health.degraded_transcripts", comment: "Completed with warnings"))
            } footer: {
                Text(NSLocalizedString("health.degraded_transcripts_footer", comment: "Explains degraded transcripts"))
            }
        }
    }

    @ViewBuilder
    var quarantineSection: some View {
        if !quarantineItems.isEmpty {
            Section {
                ForEach(quarantineItems, id: \.id) { item in
                    HStack {
                        rowLabel(
                            title: item.reason.localizedDescription,
                            subtitle: "\(item.quarantinedAt.meetingDisplay) · \(AudioFileStore.formattedSize(item.byteSize))",
                            systemImage: "shippingbox.fill",
                            tint: .red
                        )
                        Spacer()
                        Button {
                            recoverQuarantined(item)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            exportQuarantined(item)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            pendingQuarantineDeletion = item
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .tint(.red)
                    }
                }
            } header: {
                Text(NSLocalizedString("quarantine.section", comment: "Preserved recordings"))
            } footer: {
                Text(NSLocalizedString("quarantine.footer", comment: "Explains the quarantine"))
            }
        }
    }

    @ViewBuilder
    var modelsSection: some View {
        if !corruptModels.isEmpty {
            Section {
                ForEach(corruptModels) { model in
                    HStack {
                        rowLabel(
                            title: model.displayName,
                            subtitle: NSLocalizedString("settings.models.corrupt", comment: "Model failed verification"),
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .red
                        )
                        Spacer()
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
            } header: {
                Text(NSLocalizedString("health.model_verification", comment: "Model verification"))
            } footer: {
                Text(NSLocalizedString("health.model_verification_footer", comment: "Explains model verification"))
            }
        }
    }

    @ViewBuilder
    var eventsSection: some View {
        if !recentFailures.isEmpty {
            Section {
                ForEach(Array(recentFailures.enumerated()), id: \.offset) { _, event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.logLine)
                            .font(.system(.footnote, design: .monospaced))
                        Text(event.recordedAt.meetingDisplay)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                }
                NavigationLink {
                    ReliabilityEventsListView()
                } label: {
                    Text(NSLocalizedString("health.view_all_events", comment: "View all reliability events"))
                }
                .accessibilityIdentifier("health.view_all_events")
            } header: {
                Text(NSLocalizedString("health.recent_failures", comment: "Recent failure codes"))
            }
        }
    }

    func meetingTitle(for recording: Recording) -> String {
        HealthRecoveryAggregation.meetingTitle(for: recording)
    }

    func rowLabel(title: String, subtitle: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}
