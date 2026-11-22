//
//  RecordingSegmentRow.swift
//  Kurn
//
//  One recording in `MeetingDetailView`'s Audio tab: a play/pause well,
//  title + "time · duration" subtitle, a trailing transcription status, and
//  an actions menu (also the row's context menu) holding re-transcribe,
//  enhanced audio and delete. Playback controls live in the separate player
//  card under the section once the recording is loaded. Split out of
//  `MeetingDetailView.swift`; it reads everything from its parameters, so it
//  holds no meeting state of its own.
//

import KurnCore
import SwiftUI

struct RecordingSegmentRow: View {
    let recording: Recording
    let index: Int
    let player: AudioPlayerService
    let transcription: TranscriptionCoordinator?
    let enhancement: PlaybackEnhancementViewModel
    @Binding var pendingRetranscribe: Recording?
    let onTogglePlay: () -> Void
    let onToggleEnhancement: () -> Void
    let onCancelTranscription: () -> Void
    let onStopTranscription: () -> Void
    let onStartTranscription: () -> Void
    let onRetryCaptureRecovery: () -> Void
    let onRequestDelete: () -> Void

    private var isLoaded: Bool { player.loadedFileName == recording.fileName }
    private var isTranscribing: Bool { transcription?.isTranscribing(recording) == true }
    private var isCancelling: Bool { transcription?.isCancelling(recording) == true }
    private var phase: TranscriptionPhase? { transcription?.phase(for: recording) }
    private var postTranscriptionPhase: PostTranscriptionPhase? { transcription?.postTranscriptionPhase(for: recording) }
    private var enhancementProgress: Double? { enhancement.progress(for: recording) }
    private var isEnhancing: Bool { enhancementProgress != nil }
    private var isTranscribed: Bool { recording.transcriptionStatus == .done && recording.transcript?.segments.isEmpty == false }

    var body: some View {
        HStack(spacing: 12) {
            playWell
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: NSLocalizedString("detail.recording_n", comment: ""), index + 1))
                    .font(Theme.body)
                    .foregroundStyle(Theme.textPrimary)
                if isTranscribing {
                    Text(transcribingStatus)
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    ProgressView(value: (phase ?? .preparing).fractionComplete)
                        .tint(Theme.ink)
                } else {
                    Text(subtitle)
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    statusLine
                }
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                trailingStatus
                actionsMenu
            }
            .fixedSize()
        }
        .padding(.vertical, 4)
        .contextMenu { menuItems }
    }

    // MARK: - Leading

    private var playWell: some View {
        Button { onTogglePlay() } label: {
            ZStack {
                Circle().fill(Theme.fill).frame(width: 36, height: 36)
                if recording.isCaptureInProgress {
                    Image(systemName: "record.circle")
                        .foregroundStyle(Theme.record)
                } else if !recording.isReadyForConsumption {
                    Image(systemName: "waveform.badge.exclamationmark")
                        .foregroundStyle(Theme.warning)
                } else if isEnhancing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: (isLoaded && player.isPlaying) ? "pause.fill" : "play.fill")
                        .foregroundStyle(Theme.ink)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isEnhancing || !recording.isReadyForConsumption)
        .accessibilityLabel(
            recording.isCaptureInProgress
                ? NSLocalizedString("detail.recording_in_progress", comment: "Recording in progress")
                : !recording.isReadyForConsumption
                ? NSLocalizedString("detail.recording_recovery_needed", comment: "Recording needs recovery")
                : (isEnhancing
                    ? NSLocalizedString("detail.enhancing_audio", comment: "Enhancing audio")
                    : ((isLoaded && player.isPlaying)
                        ? NSLocalizedString("detail.pause_recording", comment: "Pause recording")
                        : NSLocalizedString("detail.play_recording", comment: "Play recording")))
        )
    }

    /// "<time> · <duration>", plus " · not transcribed" while the recording
    /// has no transcript.
    private var subtitle: String {
        var text = "\(recording.recordedAt.shortTime) · \(recording.duration.clockDisplay)"
        if recording.transcriptionStatus != .done {
            text += " · \(NSLocalizedString("detail.recording.not_transcribed", comment: "not transcribed"))"
        }
        return text
    }

    /// The one status line under the subtitle: capture running, recovery
    /// needed, transcription/post-transcription work, or enhancement progress.
    @ViewBuilder
    private var statusLine: some View {
        if recording.isCaptureInProgress {
            Text(NSLocalizedString("detail.recording_in_progress", comment: "Recording in progress"))
                .font(Theme.caption2)
                .foregroundStyle(Theme.record)
        } else if !recording.isReadyForConsumption {
            Text(NSLocalizedString(
                "detail.recording_recovery_message",
                comment: "The recording is preserved but unavailable until recovery succeeds"
            ))
            .font(Theme.caption2)
            .foregroundStyle(Theme.warning)
        } else if let postTranscriptionPhase {
            HStack(spacing: 6) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                Text(postTranscriptionPhase.displayName)
                    .font(Theme.caption2)
                    .foregroundStyle(Theme.textTertiary)
            }
        } else if !isLoaded, let enhancementProgress {
            EnhancementProgressView(progress: enhancementProgress)
        } else if recording.transcriptionStatus == .pending {
            Text(NSLocalizedString("meetings.status.queued", comment: "Queued to resume"))
                .font(Theme.footnote)
                .foregroundStyle(Theme.textSecondary)
        } else if recording.transcriptionStatus == .failed {
            Text(NSLocalizedString("status.failed", comment: "Failed"))
                .font(Theme.footnote)
                .foregroundStyle(Theme.destructive)
        }
    }

    /// "<phase>… <overall %>": the phase's base name (which already carries
    /// its ellipsis) plus the single `fractionComplete` percent.
    private var transcribingStatus: String {
        let active = phase ?? .preparing
        return "\(active.baseName) \(Int((active.fractionComplete * 100).rounded()))%"
    }

    // MARK: - Trailing status

    @ViewBuilder
    private var trailingStatus: some View {
        if recording.isCaptureInProgress {
            EmptyView()
        } else if !recording.isReadyForConsumption {
            Button {
                onRetryCaptureRecovery()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(Theme.footnoteEmphasized)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.fill, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("detail.retry_recovery", comment: "Retry recording recovery"))
        } else if isTranscribing {
            if isCancelling {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Button {
                    onCancelTranscription()
                } label: {
                    Image(systemName: "pause.fill")
                        .font(Theme.footnoteEmphasized)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(Theme.fill, in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("detail.cancel_transcription", comment: "Pause transcription"))
            }
        } else if recording.transcriptionStatus == .pending {
            // Interrupted mid-run with a checkpoint; tapping resumes right
            // away instead of waiting for the next foreground pass.
            Button {
                onStartTranscription()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(Theme.footnoteEmphasized)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Theme.fill, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("detail.resume_transcription", comment: "Resume transcription"))
        } else if recording.transcriptionStatus == .done {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(Theme.success)
                .accessibilityLabel(NSLocalizedString("status.done", comment: "Transcribed"))
        } else if recording.transcriptionStatus == .failed {
            Button {
                onStartTranscription()
            } label: {
                Text(NSLocalizedString("detail.recording.try_again", comment: "Try again"))
                    .font(Theme.footnoteEmphasized)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 30)
                    .background(Theme.fill, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if recording.transcriptionStatus == .inProgress {
            // Persisted `.inProgress` but not actually running in this
            // process (a stale row awaiting the next recovery sweep, which
            // moves it to `.pending` to resume or `.failed` to retry).
            // Show the honest badge without a dead start button.
            StatusBadge(status: .inProgress)
        } else {
            Button {
                onStartTranscription()
            } label: {
                Text(NSLocalizedString("detail.transcribe", comment: "Transcribe"))
                    .font(Theme.footnoteEmphasized)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 30)
                    .background(Theme.fill, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions menu / context menu

    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(NSLocalizedString("detail.recording.actions", comment: "Recording actions"))
        .accessibilityIdentifier("recording.actions")
    }

    /// Shared by the trailing ⋯ menu and the long-press context menu.
    @ViewBuilder
    private var menuItems: some View {
        if isTranscribed {
            Button {
                pendingRetranscribe = recording
            } label: {
                Label(NSLocalizedString("detail.retranscribe", comment: "Re-transcribe"), systemImage: "arrow.clockwise")
            }
        }
        Toggle(isOn: Binding(
            get: { isLoaded && player.isPlayingEnhanced },
            set: { _ in onToggleEnhancement() }
        )) {
            Label(NSLocalizedString("detail.playback_enhancement", comment: "Enhanced audio"), systemImage: "wand.and.stars")
        }
        .disabled(!recording.isReadyForConsumption || isEnhancing)
        Divider()
        Button(role: .destructive) {
            onRequestDelete()
        } label: {
            Label(NSLocalizedString("detail.recording.delete", comment: "Delete recording"), systemImage: "trash")
        }
    }
}

extension View {
    /// Confirmation dialog before deleting a recording — reached from the
    /// row's ⋯ menu, its long-press context menu, and the swipe action, so
    /// all three ask once at the root of `MeetingDetailView`.
    func recordingDeleteDialog(
        pending: Binding<Recording?>,
        onConfirm: @escaping (Recording) -> Void
    ) -> some View {
        kurnDialog(
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            iconSystemName: "trash.circle.fill",
            iconTint: Theme.destructive,
            title: NSLocalizedString("detail.recording.delete_confirm.title", comment: "Delete recording confirmation"),
            message: NSLocalizedString("detail.recording.delete_confirm.message", comment: "Delete recording message"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                guard let recording = pending.wrappedValue else { return }
                onConfirm(recording)
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }
}
