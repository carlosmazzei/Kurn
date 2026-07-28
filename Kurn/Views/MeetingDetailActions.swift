//
//  MeetingDetailActions.swift
//  Kurn
//
//  Playback, transcription, summary, sharing, and deletion actions for
//  `MeetingDetailView`. Isolated here so the main view file stays under
//  SwiftLint's file-length limit.
//

import SwiftUI

extension MeetingDetailView {

    // `meeting.recordings` itself is not used here: SwiftData doesn't refresh
    // the in-memory relationship array on this already-on-screen `Meeting`
    // when a `Recording` sets its inverse from the child side (as the recorder
    // sheet does), so a segment just added wouldn't show up until the meeting
    // was refetched. `queriedRecordings` is a `@Query` instead, which re-runs
    // against the store on every context save.
    var sortedRecordings: [Recording] {
        queriedRecordings
    }

    var totalDuration: TimeInterval {
        sortedRecordings.reduce(0) { $0 + $1.duration }
    }

    var hasAnyTranscript: Bool {
        sortedRecordings.contains { $0.transcript?.segments.isEmpty == false }
    }

    /// Mirrors `Meeting.startOffset(of:)`, sourced from `sortedRecordings`
    /// (the live `@Query`) instead of `meeting.recordings`.
    func startOffset(of recording: Recording) -> TimeInterval {
        sortedRecordings
            .prefix { $0.id != recording.id }
            .reduce(0) { $0 + $1.duration }
    }

    /// The summary currently shown in the Summary tab — used both for
    /// rendering and for export, so the two can never disagree.
    var selectedSummary: Summary? {
        meeting.summaries.first { $0.id == selectedSummaryID } ?? meeting.latestSummary
    }

    func togglePlay(_ recording: Recording) {
        do {
            if player.loadedFileName == recording.fileName {
                player.togglePlayPause()
            } else {
                try player.load(fileName: recording.fileName)
                player.play()
            }
        } catch let error as AppError {
            txVM?.error = error
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }

    func seek(_ recording: Recording, to time: TimeInterval) {
        do {
            if player.loadedFileName != recording.fileName {
                try player.load(fileName: recording.fileName)
            }
            player.seek(to: time)
            player.play()
        } catch let error as AppError {
            txVM?.error = error
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }

    func startTranscription(_ recording: Recording) {
        // Routed through the view model's task registry so the run can be
        // cancelled (by the user or when the background grace window expires).
        txVM?.startTranscription(
            recording,
            language: meeting.language,
            config: settings.pipelineConfiguration
        )
    }

    func cancelTranscription(_ recording: Recording) {
        txVM?.cancelTranscription(recording)
    }

    func stopTranscription(_ recording: Recording) {
        txVM?.stopTranscription(recording)
    }

    func retranscribe(_ recording: Recording) {
        // `transcribe` replaces any existing transcript for this recording.
        startTranscription(recording)
    }

    func retranscribeAll() {
        guard let txVM else { return }
        Task {
            await txVM.retranscribeAll(
                meeting,
                language: meeting.language,
                config: settings.pipelineConfiguration
            )
        }
    }

    func generateSummary() {
        showingTemplatePicker = true
    }

    func runSummary(with template: SummaryTemplate) {
        guard let txVM else { return }
        settings.lastSummaryTemplateID = template.id
        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        txVM.startSummary(
            for: meeting,
            provider: provider,
            model: model,
            template: template
        )
    }

    func cancelSummary() {
        txVM?.cancelSummary()
    }

    func deleteSummary(_ summary: Summary) {
        modelContext.delete(summary)
        if let failure = modelContext.saveOrError() { txVM?.error = failure }
        if selectedSummaryID == summary.id {
            selectedSummaryID = meeting.latestSummary?.id
        }
    }

    func deleteRecording(_ recording: Recording) {
        if player.loadedFileName == recording.fileName { player.stop() }
        let viewModel = MeetingsViewModel(modelContext: modelContext)
        viewModel.deleteRecording(recording)
        if let failure = viewModel.error { txVM?.error = failure }
    }
}
