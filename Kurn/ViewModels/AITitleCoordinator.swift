//
//  AITitleCoordinator.swift
//  Kurn
//

import Foundation
import KurnCore
import Observation

@MainActor
@Observable
final class AITitleCoordinator {
    private let summaryService: SummaryService
    private let providerCircuitBreaker: ProviderCircuitBreaker

    /// Meetings whose title is being (re)generated, mirroring
    /// `WikiCoordinator.generatingMeetingIDs` — lets a view show progress and
    /// coalesces a repeat request for the same meeting instead of racing it.
    private(set) var generatingMeetingIDs: Set<UUID> = []

    /// Most recent failure from an *explicit* run, for a view to surface via
    /// `.errorAlert`. Never set by an automatic background failure — see
    /// `generateTitle`'s catch block — the same contract
    /// `WikiCoordinator.lastError` has.
    var lastError: AppError?

    init(
        summaryService: SummaryService = SummaryService(),
        providerCircuitBreaker: ProviderCircuitBreaker = .shared
    ) {
        self.summaryService = summaryService
        self.providerCircuitBreaker = providerCircuitBreaker
    }

    /// Generate (or, with `force`, regenerate) `meeting`'s AI title.
    /// Best-effort: never throws, returns `nil` on any skip or failure. A
    /// real failure is recorded in `lastError` and as a `ReliabilityEvent`
    /// rather than only logged, so it surfaces the same way a wiki or
    /// document generation failure does instead of vanishing silently.
    @discardableResult
    func generateTitle(
        for meeting: Meeting,
        settings: AppSettings,
        trigger: ProviderAutomationTrigger = .automatic,
        force: Bool = false
    ) async -> String? {
        let meetingID = meeting.id
        guard !generatingMeetingIDs.contains(meetingID),
              force || meeting.aiTitle == nil,
              meeting.hasAnyTranscript else { return nil }
        let provider = settings.aiProvider
        guard provider.isUsable else { return nil }
        guard await providerCircuitBreaker.allows(
            providerID: provider.id,
            trigger: trigger
        ) else {
            AppLog.transcription.atInfo.info("AI title: skipped by provider circuit")
            return nil
        }

        let groups = meeting.recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .compactMap { recording -> SummaryService.TranscriptGroup? in
                guard let segments = recording.transcript?.segments else { return nil }
                return SummaryService.TranscriptGroup(
                    offset: meeting.startOffset(of: recording),
                    segments: segments,
                    highlights: recording.highlights
                )
            }
        let transcriptText = SummaryService.assembleTranscriptText(from: groups)
        guard !transcriptText.isEmpty else { return nil }

        generatingMeetingIDs.insert(meetingID)
        defer { generatingMeetingIDs.remove(meetingID) }

        let runID = OperationID()
        let startedAt = Date()
        do {
            let title = try await summaryService.generateTitle(
                transcriptText: transcriptText,
                provider: provider,
                model: settings.summaryModel(for: provider)
            )
            try Task.checkCancellation()
            await providerCircuitBreaker.recordSuccess(providerID: provider.id)
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "title_generation",
                outcome: .succeeded, elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            return title
        } catch is CancellationError {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "title_generation",
                outcome: .cancelled, elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            return nil
        } catch {
            await providerCircuitBreaker.recordFailure(
                providerID: provider.id,
                failure: ProviderCircuitFailure(error: error)
            )
            let code = (error as? AppError)?.logCode ?? "unexpected"
            AppLog.transcription.atInfo.info("AI title: failed code=\(code, privacy: .public)")
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "title_generation",
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt), code: code
            ))
            // Only an explicit, user-initiated run surfaces its failure — an
            // automatic background attempt stays silent-but-logged, per this
            // type's original "never a user-facing error" contract.
            if trigger == .explicit {
                lastError = (error as? AppError) ?? .titleGenerationFailed(error.localizedDescription)
            }
            return nil
        }
    }
}
