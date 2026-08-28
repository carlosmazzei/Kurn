//
//  DocumentGenerationViewModel.swift
//  Kurn
//

import Foundation
import KurnCore
import Observation
import SwiftData

@MainActor
@Observable
final class DocumentGenerationViewModel {
    private let modelContext: ModelContext
    private let service = DocumentGenerationService()

    private(set) var isGenerating = false
    private(set) var progress: (current: Int, total: Int)?
    var error: AppError?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func generate(
        meetings: [Meeting],
        prompt: String,
        sourceKind: DocumentSourceKind,
        sourceNames: [String],
        settings: AppSettings
    ) async -> GeneratedDocument? {
        guard !isGenerating else { return nil }
        let runID = String(UUID().uuidString.prefix(8))
        let startedAt = Date()
        let sources = meetings.compactMap { meeting -> DocumentTranscriptSource? in
            let transcript = meeting.assembledTranscriptText()
            guard !transcript.isEmpty else { return nil }
            return DocumentTranscriptSource(
                meetingID: meeting.id,
                title: meeting.title,
                date: meeting.createdAt,
                transcript: transcript
            )
        }
        guard !sources.isEmpty else {
            AppLog.generation.atError.error(
                "document: rejected run=\(runID, privacy: .public) stage=source_resolution code=no_transcripts"
            )
            error = .documentGenerationFailed(
                NSLocalizedString("documents.error.no_transcripts", comment: "No selected transcripts")
            )
            return nil
        }

        isGenerating = true
        progress = nil
        error = nil
        defer {
            isGenerating = false
            progress = nil
        }

        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        do {
            let result = try await service.generate(
                sources: sources,
                prompt: prompt,
                provider: provider,
                model: model,
                runID: runID,
                onProgress: { [weak self] current, total in
                    Task { @MainActor in self?.progress = (current, total) }
                }
            )
            let document = GeneratedDocument(
                title: result.title,
                bodyMarkdown: result.markdown,
                userPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                sourceKind: sourceKind,
                sourceNames: sourceNames,
                sourceMeetingIDs: sources.map(\.meetingID),
                generatorModelIdentifier: "\(provider.id):\(model)"
            )
            modelContext.insert(document)
            if let saveError = modelContext.saveOrError() {
                modelContext.delete(document)
                AppLog.generation.atError.error(
                    "document: failed run=\(runID, privacy: .public) stage=persistence code=\(saveError.logCode, privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s"
                )
                error = saveError
                return nil
            }
            AppLog.generation.atNotice.notice(
                "document: saved run=\(runID, privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s"
            )
            return document
        } catch is CancellationError {
            AppLog.generation.atNotice.notice(
                "document: cancelled run=\(runID, privacy: .public) stage=view_model elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s"
            )
            return nil
        } catch let appError as AppError {
            AppLog.generation.atError.error(
                "document: surfaced run=\(runID, privacy: .public) code=\(appError.logCode, privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s"
            )
            error = appError
            return nil
        } catch {
            AppLog.generation.atError.error(
                "document: surfaced run=\(runID, privacy: .public) code=unexpected elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s"
            )
            self.error = .documentGenerationFailed(error.localizedDescription)
            return nil
        }
    }
}
