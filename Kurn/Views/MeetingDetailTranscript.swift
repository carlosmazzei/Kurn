//
//  MeetingDetailTranscript.swift
//  Kurn
//
//  The Transcript tab of `MeetingDetailView`: the per-recording banners
//  (corrupted transcript, diarization fallback, pipeline warnings) above the
//  `TranscriptTab` content, and the empty-state copy when nothing has a
//  transcript yet. Split out of `MeetingDetailView.swift` to keep it under
//  SwiftLint's file-length limit.
//

import KurnCore
import SwiftUI

extension MeetingDetailView {
    @ViewBuilder
    var transcriptTab: some View {
        let transcribed = sortedRecordings.filter { $0.transcript?.segments.isEmpty == false }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sortedRecordings, id: \.id) { recording in
                if recording.transcript?.isSegmentsDataCorrupted == true {
                    transcriptCorruptedBanner
                }
                if let warning = transcription?.diarizationWarnings[recording.id] {
                    diarizationWarningBanner(warning)
                }
                pipelineWarningsBanner(for: recording)
            }
            if transcribed.isEmpty {
                transcriptEmptyPlaceholder
            } else {
                TranscriptTab(
                    meeting: meeting,
                    recordings: transcribed,
                    player: player,
                    offsetFor: { startOffset(of: $0) },
                    onSeek: { rec, time in seek(rec, to: time) },
                    onRenameCommit: { if let failure = modelContext.saveOrError() { actionError = failure } },
                    onDeletePhoto: { deletePhoto($0) }
                )
            }
        }
    }

    /// Which empty-state copy to show when no recording has a real (non-empty)
    /// transcript: distinguishes "corrupted" (checked first — a transcript
    /// that failed its integrity check is a more specific, more actionable
    /// diagnosis than any of the states below, which is why it takes
    /// priority even though every one of them would also technically match
    /// on a corrupted transcript's `segments == []`), "transcribing now",
    /// "failed" (so a stale or zero-segment transcript from a previous run
    /// never leaves the tab stuck blank instead of reverting here), "done
    /// but no speech detected" (a legitimately silent recording, not a
    /// failure), and "never attempted".
    @ViewBuilder
    var transcriptEmptyPlaceholder: some View {
        if sortedRecordings.contains(where: { $0.transcript?.isSegmentsDataCorrupted == true }) {
            placeholder(
                icon: "exclamationmark.triangle",
                title: NSLocalizedString("detail.transcript.corrupted.title", comment: ""),
                subtitle: NSLocalizedString("detail.transcript.corrupted.subtitle", comment: "")
            )
        } else if let running = sortedRecordings.first(where: { transcription?.isTranscribing($0) == true }) {
            transcribingState(running)
        } else if let failed = sortedRecordings.first(where: { $0.transcriptionStatus == .failed }) {
            transcriptionFailedState(failed)
        } else if sortedRecordings.contains(where: { $0.transcriptionStatus == .done && $0.transcript?.segments.isEmpty != false }) {
            ContentUnavailableView {
                Label(
                    NSLocalizedString("detail.transcript.no_speech.title", comment: ""),
                    systemImage: "waveform.slash"
                )
            } description: {
                Text(NSLocalizedString("detail.transcript.no_speech.subtitle", comment: ""))
            }
            .padding(.top, 24)
        } else {
            ContentUnavailableView {
                Label(
                    NSLocalizedString("detail.transcript.empty.title", comment: ""),
                    systemImage: "text.alignleft"
                )
            } description: {
                Text(NSLocalizedString("detail.transcript.empty.subtitle", comment: ""))
            } actions: {
                if !sortedRecordings.isEmpty {
                    Button {
                        tab = .recordings
                    } label: {
                        Text(NSLocalizedString("detail.transcript.go_to_audio", comment: "Go to Audio tab"))
                    }
                    .inkProminent()
                }
            }
            .padding(.top, 24)
        }
    }

    /// A transcription running right now: the phase in words as the title,
    /// a determinate bar with its percent, the leave-screen hint, and the
    /// same pause/stop actions the Audio tab's row offers.
    private func transcribingState(_ recording: Recording) -> some View {
        let phase = transcription?.phase(for: recording)
        let active = phase ?? .preparing
        let percent = Int((active.fractionComplete * 100).rounded())
        // "Separating speakers" — the phase name with the trailing ellipsis
        // stripped; the percent lives under the bar instead.
        let title = active.baseName.trimmingCharacters(in: CharacterSet(charactersIn: "…."))
        return ContentUnavailableView {
            Label(title, systemImage: "waveform")
        } description: {
            VStack(spacing: 10) {
                ProgressView(value: active.fractionComplete)
                    .tint(Theme.ink)
                    .frame(width: 200)
                Text("\(percent)%")
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Text(NSLocalizedString("detail.transcript.leave_hint", comment: "You can leave this screen"))
            }
        } actions: {
            HStack(spacing: 12) {
                Button {
                    cancelTranscription(recording)
                } label: {
                    Text(NSLocalizedString("recorder.pause", comment: "Pause"))
                }
                .buttonStyle(.bordered)
                Button {
                    stopTranscription(recording)
                } label: {
                    Text(NSLocalizedString("recorder.stop", comment: "Stop"))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 24)
    }

    /// The last run failed: the error itself, a reassurance the audio is
    /// safe, a retry, and a link straight to the engine settings.
    private func transcriptionFailedState(_ recording: Recording) -> some View {
        let errorText = transcription?.transcriptionError(for: recording)?.errorDescription
            ?? NSLocalizedString("detail.transcript.failed.subtitle", comment: "")
        return ContentUnavailableView {
            Label {
                Text(NSLocalizedString("detail.transcript.failed.title", comment: ""))
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.destructive)
            }
        } description: {
            Text("\(errorText) \(NSLocalizedString("detail.transcript.failed.hint", comment: "Audio is kept"))")
        } actions: {
            Button {
                startTranscription(recording)
            } label: {
                Text(NSLocalizedString("detail.try_again", comment: "Try again"))
            }
            .inkProminent()
            Button {
                showingNetworkSettings = true
            } label: {
                Text(NSLocalizedString("detail.transcript.open_settings", comment: "Transcription settings"))
                    .foregroundStyle(Theme.link)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 24)
    }

    /// Shown per recording (like `diarizationWarningBanner` below) rather
    /// than only in `transcriptEmptyPlaceholder`: a meeting with several
    /// recordings shows the transcript tab's normal content the moment any
    /// *one* of them decodes cleanly, so a corrupted sibling would never
    /// reach that all-empty placeholder at all without its own banner here.
    var transcriptCorruptedBanner: some View {
        Label(
            NSLocalizedString("detail.transcript.corrupted_banner", comment: "This recording's transcript could not be loaded"),
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .foregroundStyle(Theme.warning)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func diarizationWarningBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
            // The consent prompt lives here, not only in Settings. The neural
            // diarizer is the default, but it cannot download itself, and a user
            // who never opens Settings would silently keep the fallback engine
            // forever — the new default would reach nobody. This is the one
            // moment they can see the difference it would make.
            if settings.diarizationEngine == .fluidAudio,
               !settings.fluidAudioDiarizationModelsConsented {
                Button {
                    downloads.selectDiarizationEngine(.fluidAudio, settings: settings)
                } label: {
                    Text(NSLocalizedString(
                        "detail.download_diarization_models",
                        comment: "Download the speaker separation models"
                    ))
                    .font(.footnote.weight(.semibold))
                }
                .inkProminent()
                .disabled(downloads.isDownloading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// "Completed with warnings" for `recording`'s durable `PipelineReport`
    /// (H5 PR 13) — distinct from `diarizationWarningBanner` above, which is
    /// transient in-memory state for the run that just finished. This reads
    /// from what was actually persisted, so it still shows after navigating
    /// away and back, or for a transcript from an earlier session. Correction
    /// is the one stage cheap enough to retry in isolation (see
    /// `TranscriptionCoordinator.retryCorrection`); every other warning falls
    /// back to the existing full re-transcribe confirmation.
    @ViewBuilder
    func pipelineWarningsBanner(for recording: Recording) -> some View {
        if let report = recording.transcript?.pipelineReport, report.hasWarnings {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    String(
                        format: NSLocalizedString(
                            "detail.transcript.warnings_banner",
                            comment: "Completed with warnings in: %@"
                        ),
                        report.warnings.map { $0.stage.displayName }.joined(separator: ", ")
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                HStack(spacing: 8) {
                    if report.warnings.contains(where: { $0.stage == .correction }) {
                        let isRetrying = transcription?.correctionRetryIDs.contains(recording.id) == true
                        Button {
                            transcription?.retryCorrection(recording, language: meeting.language, config: settings.pipelineConfiguration)
                        } label: {
                            if isRetrying {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(NSLocalizedString("detail.retry_correction", comment: "Retry Correction"))
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRetrying)
                    }
                    Button {
                        pendingRetranscribe = recording
                    } label: {
                        Text(NSLocalizedString("detail.retranscribe", comment: "Re-transcribe"))
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
