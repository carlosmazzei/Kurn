//
//  SummaryTemplate.swift
//  Kurn
//
//  A reusable summarization template — a name and the instructions that shape
//  the summary a provider produces, including which sections it should have.
//  Built-ins are presets defined here; users can add, edit, and delete custom
//  templates (see AppSettings.summaryTemplates). Mirrors the `AIProvider`
//  value-type pattern.
//
//  Templates used to carry a separate list of suggested section headings. It
//  said nothing the instructions could not say ("organize it into Done, Next,
//  Blockers"), so it was folded into them: a stored or synced template that
//  still has one is migrated on decode (`instructions(_:foldingIn:)`).
//

import Foundation

struct SummaryTemplate: Codable, Sendable, Identifiable, Hashable {
    var id: String
    /// User-entered name for custom templates. Built-ins resolve `displayName`
    /// from a localization key instead.
    var name: String
    /// SF Symbol shown in the picker and editor.
    var iconName: String
    /// Persona/focus instructions injected into the system prompt, naming the
    /// sections the summary should have when the template wants particular ones.
    var instructions: String
    /// One line saying what the template is for, shown under its name in the
    /// template lists. Empty means "not written": built-ins then show their
    /// localized description and custom templates the start of their
    /// instructions (`summaryDescription`).
    var details: String
    var isBuiltIn: Bool
    var createdAt: Date
    /// Last edit time. Drives `TemplateSyncMerger`'s last-write-wins resolution
    /// when the same template was edited on two devices before iCloud sync ran.
    var updatedAt: Date

    /// Built-in names/descriptions are localized; custom templates use `name`.
    var displayName: String {
        isBuiltIn ? NSLocalizedString("template.\(id).name", comment: "Template name") : name
    }

    /// The line under the template's name in the picker and in Settings: the
    /// description the user wrote, else a built-in's localized one, else the
    /// first sentence of the instructions.
    var summaryDescription: String {
        let written = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !written.isEmpty { return written }
        if isBuiltIn {
            return NSLocalizedString("template.\(id).desc", comment: "Template description")
        }
        return Self.firstSentence(of: instructions)
    }

    /// The first sentence (or line) of `text`, for a description nobody wrote.
    static func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
        var sentence = ""
        for (index, character) in zip(firstLine.indices, firstLine) {
            sentence.append(character)
            guard terminators.contains(character) else { continue }
            let next = firstLine.index(after: index)
            if next == firstLine.endIndex || firstLine[next].isWhitespace || !character.isASCII { break }
        }
        return sentence.trimmingCharacters(in: .whitespaces)
    }

    init(
        id: String,
        name: String,
        iconName: String,
        instructions: String,
        details: String = "",
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.instructions = instructions
        self.details = details
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconName, instructions, details, sections, isBuiltIn, createdAt, updatedAt
    }

    /// Custom decode: `updatedAt` didn't exist before iCloud sync, so templates
    /// already persisted in `UserDefaults` have no such key; and a template
    /// written before sections were folded into the instructions still carries
    /// them separately (and no `details`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        iconName = try container.decode(String.self, forKey: .iconName)
        let storedInstructions = try container.decode(String.self, forKey: .instructions)
        let legacySections = try container.decodeIfPresent([String].self, forKey: .sections) ?? []
        instructions = Self.instructions(storedInstructions, foldingIn: legacySections)
        details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// Always writes an empty `sections` list: a device still running a
    /// version that requires the key decodes synced templates without it
    /// failing, and finds the headings in the instructions.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(iconName, forKey: .iconName)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(details, forKey: .details)
        try container.encode([String](), forKey: .sections)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Instructions with a legacy section list appended as one sentence, the
    /// same request the prompt used to make from that list.
    static func instructions(_ instructions: String, foldingIn sections: [String]) -> String {
        let headings = sections
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !headings.isEmpty else { return instructions }
        let sentence = "Organize the summary into sections along these lines, adapting them as the content requires: "
            + headings.joined(separator: "; ") + "."
        let base = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? sentence : base + "\n\n" + sentence
    }

    static func custom(
        name: String,
        iconName: String = "doc.text",
        instructions: String,
        details: String = ""
    ) -> SummaryTemplate {
        SummaryTemplate(
            id: "template-\(UUID().uuidString)",
            name: name,
            iconName: iconName,
            instructions: instructions,
            details: details,
            isBuiltIn: false
        )
    }

    // MARK: - Built-ins

    /// General meeting recap — reproduces the app's original summary behaviour and
    /// is the default template.
    static let general = SummaryTemplate(
        id: "general",
        name: "General Meeting",
        iconName: "sparkles",
        instructions: """
        Produce a clear, structured recap of the meeting suitable for someone who \
        did not attend. Cover the main discussion points, decisions, and follow-ups, \
        in sections along the lines of Overview, Key Points, Key Decisions and \
        Action Items.
        """,
        isBuiltIn: true
    )

    /// Daily / standup — what was done, what's next, blockers.
    static let standup = SummaryTemplate(
        id: "standup",
        name: "Daily Standup",
        iconName: "person.3",
        instructions: """
        Summarize the standup per the standard format. Focus on what each person \
        completed, what they plan to do next, and any blockers or impediments \
        raised, in three sections: Done, Next and Blockers. Attribute items to \
        people when the transcript makes it clear.
        """,
        isBuiltIn: true
    )

    /// Interview — questions, answers, and candidate assessment.
    static let interview = SummaryTemplate(
        id: "interview",
        name: "Interview",
        iconName: "person.crop.circle.badge.questionmark",
        instructions: """
        Summarize the interview. Capture the key questions asked and the \
        candidate's answers, notable strengths and concerns, and an overall \
        assessment, in sections along the lines of Questions & Answers, \
        Strengths, Concerns and Overall Assessment. Stay objective and quote the \
        candidate where helpful.
        """,
        isBuiltIn: true
    )

    /// Meeting outline — brief summary plus a hierarchical, chronological
    /// breakdown of topics discussed, without separate decisions/action items
    /// sections.
    static let outline = SummaryTemplate(
        id: "outline",
        name: "Meeting Outline",
        iconName: "list.bullet.indent",
        instructions: """
        Use two sections, Summary and Outline. Summary is a brief (2-4 sentences) \
        account of what the meeting was about and its overall outcome. Outline is \
        a pure hierarchical outline of \
        the meeting, organized chronologically by topic in the order they were \
        actually discussed (not grouped by theme). For each topic, create a \
        top-level outline entry with nested sub-points capturing the details, \
        arguments, and context raised under it, including [mm:ss] timestamps where \
        helpful. Do not add separate sections for decisions or action items — if a \
        decision or action item comes up, note it as a nested sub-point under the \
        topic where it was raised, not pulled out into its own list. Prefer \
        indentation over long prose paragraphs.
        """,
        isBuiltIn: true
    )

    static let defaultTemplates: [SummaryTemplate] = [.general, .standup, .interview, .outline]
}
