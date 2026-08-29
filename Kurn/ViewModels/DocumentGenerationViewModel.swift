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
        let runID = OperationID()
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
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation",
                stage: "source_resolution", outcome: .failed, code: "no_transcripts"
            ))
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
                ReliabilityLog.record(ReliabilityEvent(
                    operationID: runID, operation: "document_generation", stage: "persistence",
                    outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                    code: saveError.logCode
                ))
                error = saveError
                return nil
            }
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation", stage: "persistence",
                outcome: .succeeded, elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            return document
        } catch is CancellationError {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation", stage: "view_model",
                outcome: .cancelled, elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            return nil
        } catch let appError as AppError {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation", stage: "view_model",
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                code: appError.logCode
            ))
            error = appError
            return nil
        } catch {
            ReliabilityLog.record(ReliabilityEvent(
                operationID: runID, operation: "document_generation", stage: "view_model",
                outcome: .failed, elapsedSeconds: Date().timeIntervalSince(startedAt),
                code: "unexpected"
            ))
            self.error = .documentGenerationFailed(error.localizedDescription)
            return nil
        }
    }
}
