//
//  RecordingSegmentRow.swift
//  Kurn
//
//  One recording in `MeetingDetailView`'s Recordings tab: play/pause,
//  enhanced playback, transcription start/stop/cancel with its progress bar,
//  and capture recovery. Split out of `MeetingDetailView.swift`; it reads
//  everything from its parameters, so it holds no meeting state of its own.
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

    var body: some View {
        let isLoaded = player.loadedFileName == recording.fileName
        let isTranscribing = transcription?.isTranscribing(recording) == true
        let isCancelling = transcription?.isCancelling(recording) == true
        let phase = transcription?.phase(for: recording)
        let postTranscriptionPhase = transcription?.postTranscriptionPhase(for: recording)
        let enhancementProgress = enhancement.progress(for: recording)
        let isEnhancing = enhancementProgress != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { onTogglePlay() } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.fill)
                            .frame(width: 34, height: 34)
                        if !recording.isReadyForConsumption {
                            Image(systemName: "waveform.badge.exclamationmark")
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.warning)
                        } else if isEnhancing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        } else {
                            Image(systemName: (isLoaded && player.isPlaying) ? "pause.fill" : "play.fill")
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isEnhancing || !recording.isReadyForConsumption)
                .accessibilityLabel(
                    !recording.isReadyForConsumption
                        ? NSLocalizedString("detail.recording_recovery_needed", comment: "Recording needs recovery")
                        : (isEnhancing
                            ? NSLocalizedString("detail.enhancing_audio", comment: "Enhancing audio")
                            : ((isLoaded && player.isPlaying)
                                ? NSLocalizedString("detail.pause_recording", comment: "Pause recording")
                                : NSLocalizedString("detail.play_recording", comment: "Play recording")))
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: NSLocalizedString("detail.recording_n", comment: ""), index + 1))
                        .font(Theme.subheadlineEmphasized)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(recording.recordedAt.meetingDisplay) · \(recording.duration.clockDisplay)")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)

                if !recording.isReadyForConsumption {
                    Button {
                        onRetryCaptureRecovery()
                    } label: {
                        Label(
                            NSLocalizedString("detail.retry_recovery", comment: "Retry recording recovery"),
                            systemImage: "arrow.clockwise"
                        )
                        .font(Theme.captionEmphasized)
                    }
                    .buttonStyle(.bordered)
                } else if isTranscribing {
                    HStack(spacing: 8) {
                        if isCancelling {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                                .frame(width: 30, height: 30)
                        } else {
                            Button {
                                onCancelTranscription()
                            } label: {
                                Image(systemName: "pause.fill")
                                    .font(Theme.footnoteEmphasized)
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 30, height: 30)
                                    .background(Theme.fill, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(NSLocalizedString("detail.cancel_transcription", comment: "Pause transcription"))
                            Button {
                                onStopTranscription()
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(Theme.footnoteEmphasized)
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 30, height: 30)
                                    .background(Theme.fill, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(NSLocalizedString("detail.stop_transcription", comment: "Stop transcription"))
                        }
                    }
                } else if recording.transcriptionStatus == .pending {
                    // Interrupted mid-run with a checkpoint; tapping resumes
                    // right away instead of waiting for the next foreground pass.
                    Button {
                        onStartTranscription()
                    } label: {
                        StatusBadge(status: .pending)
                    }
                    .buttonStyle(.plain)
                } else if recording.transcriptionStatus == .done {
                    HStack(spacing: 8) {
                        StatusBadge(status: .done)
                        Button {
                            pendingRetranscribe = recording
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(Theme.footnoteEmphasized)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 30, height: 30)
                                .background(Theme.fill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("detail.retranscribe", comment: "Re-transcribe"))
                    }
                } else if recording.transcriptionStatus == .failed {
                    // Show the real "Failed" state (not a mislabeled "Transcribe")
                    // with a retry that restarts — resuming from the checkpoint if
                    // the interrupted run left one.
                    HStack(spacing: 8) {
                        StatusBadge(status: .failed)
                        Button {
                            onStartTranscription()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(Theme.footnoteEmphasized)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 30, height: 30)
                                .background(Theme.fill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("detail.retranscribe", comment: "Re-transcribe"))
                    }
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
                        StatusBadge(status: .none)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !recording.isReadyForConsumption {
                Text(NSLocalizedString(
                    "detail.recording_recovery_message",
                    comment: "The recording is preserved but unavailable until recovery succeeds"
                ))
                .font(.caption2)
                .foregroundStyle(Theme.warning)
            } else if isTranscribing {
                transcriptionProgressBar(phase: phase, isCancelling: isCancelling)
                if let phase, !isCancelling {
                    Text(phase.displayName)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            } else if let postTranscriptionPhase {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(postTranscriptionPhase.displayName)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if !isLoaded, let enhancementProgress {
                EnhancementProgressView(progress: enhancementProgress)
                    .padding(.leading, 46)
            }
            // Show the scrubber whenever this recording is the loaded one — even
            // while transcription is still running, so playback started mid-
            // transcription still surfaces the slider and speed control.
            if isLoaded {
                SegmentPlaybackScrubber(
                    currentTime: player.currentTime,
                    duration: player.duration > 0 ? player.duration : recording.duration,
                    isPlaying: player.isPlaying,
                    playbackRate: player.playbackRate,
                    isEnhanced: player.isPlayingEnhanced,
                    enhancementProgress: enhancementProgress,
                    onSeek: { player.seek(to: $0) },
                    onSkip: { player.skip(by: $0) },
                    onCycleRate: { player.cycleRate() },
                    onToggleEnhancement: onToggleEnhancement
                )
            }
        }
        .kurnCard(padding: 14, cornerRadius: 16)
    }

    /// Thin bar shown beneath the row while a transcription is running.
    /// Indeterminate while cancelling — the Swift task waits for the concurrent
    /// diarization child task to finish before the catch block runs, so the last
    /// known fraction would be stale (stuck at e.g. 88%) for that entire window.
    @ViewBuilder
    private func transcriptionProgressBar(phase: TranscriptionPhase?, isCancelling: Bool) -> some View {
        if isCancelling {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Theme.accent.opacity(0.5))
        } else if case .some(.diarizing(progress: nil)) = phase {
            // Keep a truthful fallback for diarizers that cannot report a
            // fraction instead of leaving transcription parked at 100%.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Theme.accent)
        } else {
            let fraction = (phase ?? .preparing).fractionComplete
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .kurnAnimation(.easeInOut(duration: 0.25), value: fraction)
        }
    }
}
