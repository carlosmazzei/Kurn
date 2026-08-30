//
//  AITitleCoordinator.swift
//  Kurn
//

import Foundation
import KurnCore

@MainActor
final class AITitleCoordinator {
    private let summaryService: SummaryService
    private let providerCircuitBreaker: ProviderCircuitBreaker

    init(
        summaryService: SummaryService = SummaryService(),
        providerCircuitBreaker: ProviderCircuitBreaker = .shared
    ) {
        self.summaryService = summaryService
        self.providerCircuitBreaker = providerCircuitBreaker
    }

    func generateTitle(for meeting: Meeting, settings: AppSettings) async -> String? {
        guard meeting.aiTitle == nil, meeting.hasAnyTranscript else { return nil }
        let provider = settings.aiProvider
        guard provider.isUsable else { return nil }
        guard await providerCircuitBreaker.allows(
            providerID: provider.id,
            trigger: .automatic
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

        do {
            let title = try await summaryService.generateTitle(
                transcriptText: transcriptText,
                provider: provider,
                model: settings.summaryModel(for: provider)
            )
            try Task.checkCancellation()
            await providerCircuitBreaker.recordSuccess(providerID: provider.id)
            return title
        } catch is CancellationError {
            return nil
        } catch {
            await providerCircuitBreaker.recordFailure(
                providerID: provider.id,
                failure: ProviderCircuitFailure(error: error)
            )
            let code = (error as? AppError)?.logCode ?? "unexpected"
            AppLog.transcription.atInfo.info("AI title: failed code=\(code, privacy: .public)")
            return nil
        }
    }
}
