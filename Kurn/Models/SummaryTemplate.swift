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
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.instructions = instructions
        self.sections = sections
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
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

    static let defaultTemplates: [SummaryTemplate] = [.general, .standup, .interview]
}
