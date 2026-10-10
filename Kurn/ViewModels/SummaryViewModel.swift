//
//  SummaryViewModel.swift
//  Kurn
//
//  Generating and translating a meeting's summaries — the Summary tab's work.
//  Split out of the old `SummaryViewModel`, which also owned every
//  transcription run; that half is now `TranscriptionCoordinator`
//  (Application/), because the background processing window drives it too,
//  while only the meeting screen ever starts a summary.
//
//  H4: a staged (map-reduce) summary run's map-stage checkpoint
//  (`Meeting.summaryMapCheckpoint`) is read as a resume seed before the run
//  starts and durably saved after every completed block, gating forward
//  progress the same way `TranscriptionCoordinator+ResumeBudget.swift` does
//  for transcription chunks — see `storeSummaryMapCheckpointDurably` below.
//

import Foundation
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class SummaryViewModel {
    var isSummarizing = false
    /// True after the user asks to cancel a summary while the provider request
    /// is still unwinding.
    var isCancellingSummary = false
    /// Staged-summary progress as (stage, total) when a long transcript is
    /// being summarized in parts; nil for single-pass summaries.
    var summaryProgress: (stage: Int, total: Int)?
    /// Approximate words the model has written so far in the request in
    /// flight; nil until text starts arriving, and back to nil as each
    /// staged request begins.
    var summaryWordsReceived: Int?
    /// The readable, unformatted draft of the request in flight
    /// (`SummaryDraftPreview`), shown live while the model writes and
    /// replaced by the parsed summary when it finishes. Empty before the
    /// first fragment, and again as each staged request begins.
    var summaryDraft = ""
    /// When the request now in flight started, for the "thinking" timer
    /// shown until its first fragment arrives.
    var summaryRequestStartedAt: Date?
    /// Last applied `SummaryDraftSnapshot.sequence`; snapshots hop to the
    /// main actor independently, so an older one may land after a newer one.
    private var lastDraftSequence = 0
    /// True while an existing summary is being translated into another
    /// language. Independent of `isSummarizing`/`summaryTask`: translating a
    /// summary neither blocks nor is blocked by generating a new one, and it
    /// is always single-pass so it needs no staged progress.
    var isTranslatingSummary = false
    /// The source summary and target language of the in-flight translation,
    /// so the Summary tab can show *which* chip is translating rather than a
    /// generic spinner. Set together with `isTranslatingSummary`.
    var translatingSummaryID: UUID?
    var translationTargetLanguage: MeetingLanguage?
    /// The last summary or translation failure, for the meeting screen's
    /// `.errorAlert`.
    var error: AppError?

    /// Active summary task, owned here so the detail screen can cancel it.
    var summaryTask: Task<Void, Never>?
    /// Active translation task. Not `private` —
    /// `SummaryViewModel+Translation.swift` needs it.
    var translationTask: Task<Void, Never>?

    /// Not `private` — `SummaryViewModel+Translation.swift` needs these.
    let modelContext: ModelContext
    let summaryService: SummaryService
    /// Records which template was used (`UsageStats`). `nil` only in tests.
    let appSettings: AppSettings?

    init(
        modelContext: ModelContext,
        appSettings: AppSettings? = nil,
        summaryService: SummaryService = SummaryService()
    ) {
        self.modelContext = modelContext
        self.appSettings = appSettings
        self.summaryService = summaryService
    }

    /// Persist pending model changes, surfacing a failure through `error`
    /// instead of dropping it.
    func persist() {
        if let failure = modelContext.saveOrError() { error = failure }
    }

    // MARK: - Summary

    func startSummary(
        for meeting: Meeting,
        provider: AIProvider,
        model: String,
        template: SummaryTemplate
    ) {
        guard !isSummarizing else { return }
        isSummarizing = true
        isCancellingSummary = false
        summaryProgress = nil
        resetSummaryDraft()
        summaryRequestStartedAt = Date()
        summaryTask = Task { [weak self, meeting] in
            await self?.generateSummary(
                for: meeting,
                provider: provider,
                model: model,
                template: template
            )
        }
    }

    func cancelSummary() {
        guard isSummarizing else { return }
        isCancellingSummary = true
        summaryTask?.cancel()
    }

    private func generateSummary(
        for meeting: Meeting,
        provider: AIProvider,
        model: String,
        template: SummaryTemplate
    ) async {
        // Assemble transcript text on the main actor (reads SwiftData). Each
        // group carries the recording's absolute start offset so the timestamps
        // stay chronological across multiple segments.
        let groups = meeting.recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .compactMap { recording -> SummaryService.TranscriptGroup? in
                guard let segments = recording.transcript?.segments else { return nil }
                return SummaryService.TranscriptGroup(
                    offset: meeting.startOffset(of: recording),
                    segments: segments,
                    highlights: recording.highlights,
                    photos: recording.photos
                )
            }
        let transcriptText = SummaryService.assembleTranscriptText(from: groups)
        let title = meeting.title
        // `Meeting` isn't `Sendable`; the `onMapStageCompleted` closure below
        // is, so it captures this id and looks the meeting back up on the
        // main actor rather than capturing the model object itself.
        let meetingID = meeting.id

        defer {
            isSummarizing = false
            isCancellingSummary = false
            summaryProgress = nil
            resetSummaryDraft()
            summaryTask = nil
        }

        guard !transcriptText.isEmpty else {
            error = .transcriptionFailed(
                NSLocalizedString("error.no_transcript", comment: "No transcript to summarize")
            )
            return
        }

        // A checkpoint from an earlier interrupted staged run (H4); a
        // structurally invalid one is treated the same as none, never
        // trusted. `SummaryMapRunner` itself checks the fuller identity
        // (content/provider/model/block-count) before actually resuming.
        let resumeCheckpoint = meeting.summaryMapCheckpoint.flatMap { $0.isStructurallyValid ? $0 : nil }

        AppLog.transcription.atNotice.notice("VM: summary start provider=\(provider.rawValue, privacy: .public) chars=\(transcriptText.count, privacy: .public)")
        do {
            let result = try await summaryService.generate(
                transcriptText: transcriptText,
                meetingTitle: title,
                provider: provider,
                model: model,
                template: template,
                resume: resumeCheckpoint,
                onProgress: { [weak self] stage, total in
                    // Reported off the main actor; hop back before mutating state.
                    Task { @MainActor in self?.summaryProgress = (stage, total) }
                },
                onDraft: { [weak self] snapshot in
                    Task { @MainActor in self?.recordSummaryDraft(snapshot) }
                },
                onMapStageCompleted: { [weak self] checkpoint in
                    try await self?.storeSummaryMapCheckpointDurably(checkpoint, forMeetingID: meetingID)
                }
            )
            try Task.checkCancellation()
            // Same reasoning as `saveTranscript`: fail before constructing
            // the summary, and reuse the existing `catch` below.
            guard let sectionsData = JSONStorage.encodeAuthoritative(result.sections) else {
                throw AppError.persistenceFailed(NSLocalizedString("error.summary_encode_failed", comment: "Encode failed"))
            }
            let summary = Summary(
                meeting: meeting,
                templateName: template.displayName,
                provider: provider,
                model: model
            )
            summary.sectionsData = sectionsData
            modelContext.insert(summary)
            // The staged run (if any) is fully done — map notes and reduce
            // both succeeded — so the checkpoint that got it here no longer
            // describes work still owed (H4).
            meeting.summaryMapCheckpoint = nil
            persist()
            AppLog.transcription.atNotice.notice("VM: summary done")
            appSettings?.recordSummaryTemplateUsed(template.id)
        } catch is CancellationError {
            AppLog.transcription.atNotice.notice("VM: summary cancelled")
        } catch let AppError.networkError(urlError) where urlError.code == .cancelled || Task.isCancelled || isCancellingSummary {
            AppLog.transcription.atNotice.notice("VM: summary cancelled")
        } catch let appError as AppError {
            error = appError
            AppLog.transcription.atError.error("VM: summary failed code=\(appError.logCode, privacy: .public)")
        } catch {
            self.error = .apiError(statusCode: 0, message: error.localizedDescription)
            AppLog.transcription.atError.error("VM: summary failed code=unexpected")
        }
    }

    /// Apply a draft update from the stream. Dropped when it lands after
    /// the run finished (the `defer` above already cleared state) or after a
    /// newer update, so a late hop can't resurrect stale text. An empty
    /// draft opens a new request and restarts the "thinking" timer.
    func recordSummaryDraft(_ snapshot: SummaryDraftSnapshot) {
        guard isSummarizing, snapshot.sequence > lastDraftSequence else { return }
        lastDraftSequence = snapshot.sequence
        if snapshot.text.isEmpty, !summaryDraft.isEmpty || summaryRequestStartedAt == nil {
            summaryRequestStartedAt = Date()
        }
        summaryDraft = snapshot.text
        summaryWordsReceived = snapshot.words > 0 ? snapshot.words : nil
    }

    private func resetSummaryDraft() {
        summaryDraft = ""
        summaryWordsReceived = nil
        summaryRequestStartedAt = nil
        lastDraftSequence = 0
    }

    /// Persist a staged summary run's map-stage progress so an interruption
    /// resumes from the last completed block instead of re-condensing — for
    /// a cloud provider, re-paying for — every block from the start (H4).
    /// Throws (rather than merely logging) so a save failure gates forward
    /// progress: `SummaryMapRunner` awaits this before starting the next
    /// block, and a thrown error stops the run at the last durably-committed
    /// one, the same contract `storeCheckpointDurably` has for transcription.
    ///
    /// Takes the meeting's id rather than the `Meeting` itself: `Meeting`
    /// isn't `Sendable`, and this is called from the `@Sendable` closure
    /// `generateSummary` hands to `SummaryService.generate`.
    private func storeSummaryMapCheckpointDurably(_ checkpoint: SummaryMapCheckpoint, forMeetingID meetingID: UUID) throws {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        guard let meeting = try? modelContext.fetch(descriptor).first else { return }
        meeting.summaryMapCheckpoint = checkpoint
        do {
            try modelContext.save()
        } catch {
            throw AppError.persistenceFailed(error.localizedDescription)
        }
    }
}
