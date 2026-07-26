//
//  DocumentGenerationViewModel.swift
//  Kurn
//

import Foundation
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
                error = saveError
                return nil
            }
            return document
        } catch is CancellationError {
            return nil
        } catch let appError as AppError {
            error = appError
            return nil
        } catch {
            self.error = .documentGenerationFailed(error.localizedDescription)
            return nil
        }
    }
}
