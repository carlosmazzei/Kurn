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
    /// on a corrupted transcript's `segments == []`), "never attempted",
    /// "failed" (so a stale or zero-segment transcript from a previous run
    /// never leaves the tab stuck blank instead of reverting here), and
    /// "done but no speech detected" (a legitimately silent recording, not
    /// a failure).
    @ViewBuilder
    var transcriptEmptyPlaceholder: some View {
        if sortedRecordings.contains(where: { $0.transcript?.isSegmentsDataCorrupted == true }) {
            placeholder(
                icon: "exclamationmark.triangle",
                title: NSLocalizedString("detail.transcript.corrupted.title", comment: ""),
                subtitle: NSLocalizedString("detail.transcript.corrupted.subtitle", comment: "")
            )
        } else if sortedRecordings.contains(where: { $0.transcriptionStatus == .failed }) {
            placeholder(
                icon: "exclamationmark.triangle",
                title: NSLocalizedString("detail.transcript.failed.title", comment: ""),
                subtitle: NSLocalizedString("detail.transcript.failed.subtitle", comment: "")
            )
        } else if sortedRecordings.contains(where: { $0.transcriptionStatus == .done && $0.transcript?.segments.isEmpty != false }) {
            placeholder(
                icon: "waveform.slash",
                title: NSLocalizedString("detail.transcript.no_speech.title", comment: ""),
                subtitle: NSLocalizedString("detail.transcript.no_speech.subtitle", comment: "")
            )
        } else {
            placeholder(
                icon: "text.alignleft",
                title: NSLocalizedString("detail.transcript.empty.title", comment: ""),
                subtitle: NSLocalizedString("detail.transcript.empty.subtitle", comment: "")
            )
        }
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
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
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
            .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}
