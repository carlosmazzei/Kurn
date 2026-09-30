//
//  MeetingDetailAutoTagging.swift
//  Kurn
//
//  Auto-tagging support for `MeetingDetailView`. Isolated here so the main
//  detail view stays focused on layout and navigation.
//

import KurnCore
import SwiftData
import SwiftUI

extension MeetingDetailView {

    /// Starts an LLM-driven tag suggestion for the current meeting and surfaces
    /// the result (or error) on the main actor.
    func suggestTags() {
        guard !isAutoTagging else { return }
        isAutoTagging = true
        let descriptor = FetchDescriptor<Kurn.Tag>(sortBy: [SortDescriptor(\.name)])
        let allTags = (try? modelContext.fetch(descriptor)) ?? []
        let title = meeting.title
        let transcript = meeting.recordings
            .compactMap { $0.transcript?.plainText }
            .joined(separator: "\n")
        let tagInputs = allTags.map { AutoTaggingService.TagInput(id: $0.id, name: $0.name) }
        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        Task { @MainActor in
            defer { isAutoTagging = false }
            do {
                autoTagSuggestion = try await AutoTaggingService().suggestTags(
                    meetingTitle: title,
                    transcript: transcript,
                    availableTags: tagInputs,
                    provider: provider,
                    model: model
                )
            } catch {
                let code = (error as? AppError)?.logCode ?? "unexpected"
                AppLog.ui.atError.error("Auto-tagging failed code=\(code, privacy: .public)")
                autoTagError = .autoTaggingFailed(error.localizedDescription)
            }
        }
    }

    /// Applies a confirmed suggestion to the meeting, creating new tags when
    /// needed and skipping duplicates.
    func applyAutoTagSuggestion(_ suggestion: AutoTaggingService.Suggestion) {
        do {
            try MeetingLibrary(context: modelContext)
                .applyTags(ids: suggestion.tagIDs, newNames: suggestion.newTagNames, to: meeting)
        } catch {
            autoTagError = error
        }
        autoTagSuggestion = nil
    }
}
