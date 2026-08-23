//
//  SummaryTemplate.swift
//  Kurn
//
//  A reusable summarization template — a persona/focus plus suggested section
//  headings that shape the structured summary a provider produces. Built-ins are
//  presets defined here; users can add, edit, and delete custom templates (see
//  AppSettings.summaryTemplates). Mirrors the `AIProvider` value-type pattern.
//

import Foundation

struct SummaryTemplate: Codable, Sendable, Identifiable, Hashable {
    var id: String
    /// User-entered name for custom templates. Built-ins resolve `displayName`
    /// from a localization key instead.
    var name: String
    /// SF Symbol shown in the picker and editor.
    var iconName: String
    /// Persona/focus instructions injected into the system prompt.
    var instructions: String
    /// Suggested section headings used to guide the model's structure. The model
    /// may adapt them and outputs them in the transcript's language.
    var sections: [String]
    var isBuiltIn: Bool
    var createdAt: Date
    /// Last edit time. Drives `TemplateSyncMerger`'s last-write-wins resolution
    /// when the same template was edited on two devices before iCloud sync ran.
    var updatedAt: Date

    /// Built-in names/descriptions are localized; custom templates use `name`.
    var displayName: String {
        isBuiltIn ? NSLocalizedString("template.\(id).name", comment: "Template name") : name
    }

    /// Short subtitle for the picker. Built-ins are localized; custom templates
    /// fall back to the first suggested section list.
    var summaryDescription: String {
        if isBuiltIn {
            return NSLocalizedString("template.\(id).desc", comment: "Template description")
        }
        return sections.joined(separator: " · ")
    }

    init(
        id: String,
        name: String,
        iconName: String,
        instructions: String,
        sections: [String],
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.instructions = instructions
        self.sections = sections
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, iconName, instructions, sections, isBuiltIn, createdAt, updatedAt
    }

    /// Custom decode: `updatedAt` didn't exist before iCloud sync, so templates
    /// already persisted in `UserDefaults` have no such key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        iconName = try container.decode(String.self, forKey: .iconName)
        instructions = try container.decode(String.self, forKey: .instructions)
        sections = try container.decode([String].self, forKey: .sections)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    static func custom(
        name: String,
        iconName: String = "doc.text",
        instructions: String,
        sections: [String]
    ) -> SummaryTemplate {
        SummaryTemplate(
            id: "template-\(UUID().uuidString)",
            name: name,
            iconName: iconName,
            instructions: instructions,
            sections: sections,
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
        did not attend. Cover the main discussion points, decisions, and follow-ups.
        """,
        sections: ["Overview", "Key Points", "Key Decisions", "Action Items"],
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
        raised. Attribute items to people when the transcript makes it clear.
        """,
        sections: ["Done", "Next", "Blockers"],
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
        assessment. Stay objective and quote the candidate where helpful.
        """,
        sections: ["Questions & Answers", "Strengths", "Concerns", "Overall Assessment"],
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
        Start with a brief summary (2-4 sentences) capturing what the meeting was \
        about and its overall outcome. Then produce a pure hierarchical outline of \
        the meeting, organized chronologically by topic in the order they were \
        actually discussed (not grouped by theme). For each topic, create a \
        top-level outline entry with nested sub-points capturing the details, \
        arguments, and context raised under it, including [mm:ss] timestamps where \
        helpful. Do not add separate sections for decisions or action items — if a \
        decision or action item comes up, note it as a nested sub-point under the \
        topic where it was raised, not pulled out into its own list. Prefer \
        indentation over long prose paragraphs.
        """,
        sections: ["Summary", "Outline"],
        isBuiltIn: true
    )

    static let defaultTemplates: [SummaryTemplate] = [.general, .standup, .interview, .outline]
}
