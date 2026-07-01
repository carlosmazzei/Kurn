//
//  MeetingDetailAutoTagging.swift
//  Kurn
//
//  Auto-tagging support for `MeetingDetailView`. Isolated here so the main
//  detail view stays focused on layout and navigation.
//

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
                AppLog.ui.atError.error("Auto-tagging failed: \(error, privacy: .public)")
                autoTagError = .autoTaggingFailed(error.localizedDescription)
            }
        }
    }

    /// Applies a confirmed suggestion to the meeting, creating new tags when
    /// needed and skipping duplicates.
    func applyAutoTagSuggestion(_ suggestion: AutoTaggingService.Suggestion) {
        let descriptor = FetchDescriptor<Kurn.Tag>(sortBy: [SortDescriptor(\.name)])
        let allTags = (try? modelContext.fetch(descriptor)) ?? []
        let existingByID = Dictionary(uniqueKeysWithValues: allTags.map { ($0.id, $0) })
        for tagID in suggestion.tagIDs {
            if let tag = existingByID[tagID],
               !meeting.tags.contains(where: { $0.id == tagID }) {
                meeting.tags.append(tag)
            }
        }
        for name in suggestion.newTagNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !allTags.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
                let newTag = Kurn.Tag(name: trimmed)
                modelContext.insert(newTag)
                meeting.tags.append(newTag)
            }
        }
        do {
            try modelContext.save()
        } catch {
            AppLog.persistence.atError.error("Failed to save auto-tagged meeting: \(error, privacy: .public)")
            autoTagError = .persistenceFailed(error.localizedDescription)
        }
        autoTagSuggestion = nil
    }
}
