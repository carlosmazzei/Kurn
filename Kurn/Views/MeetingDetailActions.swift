//
//  MeetingDetailActions.swift
//  Kurn
//
//  Playback, transcription, summary, sharing, and deletion actions for
//  `MeetingDetailView`. Isolated here so the main view file stays under
//  SwiftLint's file-length limit.
//

import SwiftUI
import KurnCore

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
        guard recording.isReadyForConsumption else { return }
        // Offline neural rendering is intentionally exclusive with starting a
        // fresh player for the same file. The shared coordinator keeps this
        // guard true even after leaving and reopening the detail screen.
        guard !enhancement.isEnhancing(recording) else { return }
        do {
            if player.loadedFileName == recording.fileName {
                player.togglePlayPause()
            } else {
                try player.load(
                    fileName: recording.fileName,
                    title: meeting.title,
                    subtitle: recording.recordedAt.formatted(date: .abbreviated, time: .shortened),
                    enhanced: shouldUseEnhanced(recording)
                )
                player.play()
            }
        } catch let error as AppError {
            txVM?.error = error
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }

    /// Play the enhanced copy only when the user has asked for it *and* a copy
    /// rendered by the current tuning is actually on disk. Falling back to the
    /// original silently is the right failure: the recording still plays.
    func shouldUseEnhanced(_ recording: Recording) -> Bool {
        settings.playbackEnhancementEnabled && enhancement.hasEnhancedAudio(recording)
    }

    /// Flip the enhanced/original variant for the recording being played,
    /// rendering the copy first if this is the first time.
    ///
    /// The preference is written too, so the choice sticks for the next recording
    /// instead of having to be made again for each one.
    func toggleEnhancement(_ recording: Recording) {
        guard recording.isReadyForConsumption else { return }
        let wantEnhanced = !player.isPlayingEnhanced
        settings.playbackEnhancementEnabled = wantEnhanced

        guard wantEnhanced else {
            applyEnhancement(false)
            return
        }
        enhancement.ensureEnhancedAudio(for: recording) {
            applyEnhancement(true)
        }
    }

    private func applyEnhancement(_ enhanced: Bool) {
        do {
            try player.reload(enhanced: enhanced)
        } catch let error as AppError {
            txVM?.error = error
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }

    func seek(_ recording: Recording, to time: TimeInterval) {
        guard !enhancement.isEnhancing(recording) else { return }
        do {
            if player.loadedFileName != recording.fileName {
                try player.load(
                    fileName: recording.fileName,
                    title: meeting.title,
                    subtitle: recording.recordedAt.formatted(date: .abbreviated, time: .shortened),
                    enhanced: shouldUseEnhanced(recording)
                )
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
        guard recording.isReadyForConsumption else { return }
        // A deliberate user action gets a fresh automatic-resume budget,
        // regardless of how many unattended attempts already failed (H4).
        txVM?.resetAutomaticResumeBudget(for: recording)
        // Routed through the view model's task registry so the run can be
        // cancelled (by the user or when the background grace window expires).
        txVM?.startTranscription(
            recording,
            language: meeting.language,
            config: settings.pipelineConfiguration
        )
    }

    func retryCaptureRecovery(_ recording: Recording) {
        if let error = RecordingRecovery.retryRecovery(for: recording, context: modelContext) {
            txVM?.error = error
        }
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

    /// Whether the overflow menu should offer a wiki action at all — needs a
    /// transcript to condense and a usable provider, same gate
    /// `TranscriptionViewModel.shouldGenerateWiki` uses for the automatic
    /// post-transcription pass. Deliberately not also gated on
    /// `settings.wikiEnabled`: a meeting missing its wiki because generation
    /// was off (or blocked) when it transcribed should still be one tap away
    /// from getting one, without the user first hunting down the toggle.
    var canGenerateWiki: Bool {
        hasAnyTranscript && settings.aiProvider.isUsable
    }

    var isGeneratingWiki: Bool {
        wiki.generatingMeetingIDs.contains(meeting.id)
    }

    /// Build (or rebuild) this meeting's wiki article from its own overflow
    /// menu, so getting one back doesn't require a trip to Settings → Wiki
    /// and a full "Rebuild All" over every other meeting too. Always
    /// explicit and forced: a deliberate per-meeting tap should run
    /// regardless of the provider circuit breaker or a matching content
    /// hash, the same way `WikiCoordinator.rebuildWiki()` treats every
    /// meeting it touches.
    func regenerateWiki() {
        Task { await wiki.generate(meeting, trigger: .explicit, force: true) }
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
        enhancement.cancel(recording)
        let viewModel = MeetingsViewModel(modelContext: modelContext)
        viewModel.deleteRecording(recording)
        if let failure = viewModel.error { txVM?.error = failure }
    }
}
