//
//  TranscriptionViewModel+SummaryTranslation.swift
//  Kurn
//
//  Summary translation, split out of TranscriptionViewModel.swift for the same
//  file-length reason as TranscriptionViewModel+Summary.swift. Translating an
//  existing summary creates a brand-new `Summary` linked to the same meeting —
//  the original is never mutated — mirroring how "Generate Summary" appends
//  another summary rather than overwriting one.
//

import Foundation
import KurnCore
import SwiftData

extension TranscriptionViewModel {

    // MARK: - Summary translation

    func startTranslateSummary(
        source: Summary,
        meeting: Meeting,
        targetLanguage: MeetingLanguage,
        provider: AIProvider,
        model: String
    ) {
        guard !isTranslatingSummary else { return }
        isTranslatingSummary = true
        translationTask = Task { [weak self] in
            await self?.translateSummary(
                source: source,
                meeting: meeting,
                targetLanguage: targetLanguage,
                provider: provider,
                model: model
            )
        }
    }

    func cancelTranslateSummary() {
        guard isTranslatingSummary else { return }
        translationTask?.cancel()
    }

    private func translateSummary(
        source: Summary,
        meeting: Meeting,
        targetLanguage: MeetingLanguage,
        provider: AIProvider,
        model: String
    ) async {
        let sourceSections = source.sections
        let sourceTemplateName = source.templateName

        defer {
            isTranslatingSummary = false
            translationTask = nil
        }

        guard !sourceSections.isEmpty else {
            error = .summaryTranslationFailed(
                NSLocalizedString("error.summary_translation_source_empty", comment: "Nothing to translate")
            )
            return
        }

        AppLog.transcription.atNotice.notice("VM: summary translation start provider=\(provider.rawValue, privacy: .public)")
        do {
            let result = try await summaryService.translate(
                sections: sourceSections,
                to: targetLanguage,
                provider: provider,
                model: model
            )
            try Task.checkCancellation()
            guard let sectionsData = JSONStorage.encodeAuthoritative(result.sections) else {
                throw AppError.persistenceFailed(NSLocalizedString("error.summary_encode_failed", comment: "Encode failed"))
            }
            let label = sourceTemplateName?.isEmpty == false
                ? "\(sourceTemplateName!) (\(targetLanguage.displayName))"
                : targetLanguage.displayName
            let translated = Summary(
                meeting: meeting,
                templateName: label,
                provider: provider,
                model: model
            )
            translated.sectionsData = sectionsData
            modelContext.insert(translated)
            persist()
            AppLog.transcription.atNotice.notice("VM: summary translation done")
        } catch is CancellationError {
            AppLog.transcription.atNotice.notice("VM: summary translation cancelled")
        } catch let AppError.networkError(urlError) where urlError.code == .cancelled || Task.isCancelled {
            AppLog.transcription.atNotice.notice("VM: summary translation cancelled")
        } catch let appError as AppError {
            error = appError
            AppLog.transcription.atError.error("VM: summary translation failed code=\(appError.logCode, privacy: .public)")
        } catch {
            self.error = .apiError(statusCode: 0, message: error.localizedDescription)
            AppLog.transcription.atError.error("VM: summary translation failed code=unexpected")
        }
    }
}
