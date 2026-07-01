//
//  AutoTaggingService.swift
//  Kurn
//
//  Suggests existing tags for a meeting by sending a lightweight excerpt of the
//  transcript + title to the configured summary provider. Off-by-default, gated
//  in Settings, and always safe to call off the main actor.
//

import Foundation

struct AutoTaggingService: Sendable {

    /// Lightweight, sendable description of a tag for the prompt.
    struct TagInput: Sendable {
        let id: UUID
        let name: String
    }

    /// Result of a tag-suggestion request.
    struct Suggestion: Sendable, Identifiable {
        let id = UUID()
        let tagIDs: [UUID]
        let newTagNames: [String]
    }

    /// Ask the model to pick the best matching tags from the existing set and
    /// optionally suggest a few new ones. Returns an empty suggestion when the
    /// input is empty or no tags are applicable.
    func suggestTags(
        meetingTitle: String,
        transcript: String,
        availableTags: [TagInput],
        provider: AIProvider,
        model: String
    ) async throws -> Suggestion {
        let trimmed = String(transcript.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3000, breakingAt: .whitespacesAndNewlines))
        guard !trimmed.isEmpty else {
            return Suggestion(tagIDs: [], newTagNames: [])
        }

        let llm = try ProviderFactory.summaryProvider(for: provider, model: model)
        let prompt = buildPrompt(
            title: meetingTitle,
            transcript: trimmed,
            availableTags: availableTags
        )
        let raw = try await llm.summarize(systemPrompt: systemPrompt, userPrompt: prompt)
        let text = raw.sections.map { $0.body }.joined(separator: "\n")
        return parseSuggestion(text: text, availableTags: availableTags)
    }

    private let systemPrompt = """
    You are a tagging assistant for a meeting app. Given a meeting title and transcript, \
    pick the most relevant tags from the provided list. You may also suggest up to 2 new \
    tags that are not in the list. Return ONLY a JSON object with no markdown fences.

    Format:
    {
      "existing": ["tag-id-1", "tag-id-2"],
      "new": ["New Tag Name"]
    }

    - Use the exact tag IDs from the list for `existing`.
    - Keep `new` short (1-3 words) and relevant. If none are needed, return an empty array.
    """

    private func buildPrompt(title: String, transcript: String, availableTags: [TagInput]) -> String {
        let tagsList = availableTags.map { "\($0.id.uuidString): \($0.name)" }.joined(separator: "\n")
        return """
        Meeting title: \(title)

        Available tags:
        \(tagsList)

        Transcript excerpt:
        \(transcript)
        """
    }

    private func parseSuggestion(text: String, availableTags: [TagInput]) -> Suggestion {
        guard let data = text.data(using: .utf8) else {
            return Suggestion(tagIDs: [], newTagNames: [])
        }
        struct Wire: Decodable {
            let existing: [String]
            let new: [String]
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return Suggestion(tagIDs: [], newTagNames: [])
        }
        let availableIDs = Set(availableTags.map(\.id))
        let existingIDs = wire.existing
            .compactMap { UUID(uuidString: $0) }
            .filter { availableIDs.contains($0) }
        let newNames = wire.new
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Suggestion(tagIDs: existingIDs, newTagNames: newNames)
    }
}

private extension String {
    /// Truncates to at most `maxLength` characters, breaking at the last
    /// occurrence of the given character set before the limit so words stay
    /// intact. Falls back to a hard cut if no break point exists.
    func prefix(_ maxLength: Int, breakingAt: CharacterSet) -> String {
        guard count > maxLength else { return self }
        let index = self.index(startIndex, offsetBy: maxLength)
        let prefix = self[..<index]
        if let lastBreak = prefix.unicodeScalars.lastIndex(where: { breakingAt.contains($0) }) {
            let end = prefix.index(after: lastBreak)
            return String(prefix[..<end])
        }
        return String(prefix)
    }
}
