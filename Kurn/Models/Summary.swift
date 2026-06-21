//
//  Summary.swift
//  Kurn
//
//  AI-generated summary for a meeting: markdown body plus extracted action items
//  and key decisions.
//

import Foundation
import SwiftData

@Model
final class Summary {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var content: String
    /// JSON-encoded `[String]`. Legacy: only populated for pre-template summaries.
    private var actionItemsData: Data
    /// JSON-encoded `[String]`. Legacy: only populated for pre-template summaries.
    private var keyDecisionsData: Data
    /// JSON-encoded `[SummarySection]` — the template-driven summary body. Defaults
    /// to empty so existing rows migrate without a custom schema.
    private var sectionsData: Data = Data()
    /// Display name of the template used to generate this summary, if any.
    var templateName: String?
    var providerRaw: String
    var modelRaw: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        meeting: Meeting? = nil,
        content: String = "",
        actionItems: [String] = [],
        keyDecisions: [String] = [],
        sections: [SummarySection] = [],
        templateName: String? = nil,
        provider: AIProvider,
        model: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meeting = meeting
        self.content = content
        self.actionItemsData = (try? JSONEncoder().encode(actionItems)) ?? Data()
        self.keyDecisionsData = (try? JSONEncoder().encode(keyDecisions)) ?? Data()
        self.sectionsData = (try? JSONEncoder().encode(sections)) ?? Data()
        self.templateName = templateName
        self.providerRaw = provider.rawValue
        self.modelRaw = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var sections: [SummarySection] {
        get { (try? JSONDecoder().decode([SummarySection].self, from: sectionsData)) ?? [] }
        set { sectionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Sections to render. Prefers the template-driven `sections`; falls back to
    /// reconstructing them from the legacy `content`/`keyDecisions`/`actionItems`
    /// fields so summaries created before templates still display correctly.
    var displaySections: [SummarySection] {
        let stored = sections
        if !stored.isEmpty { return stored }

        var legacy: [SummarySection] = []
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedContent.isEmpty {
            legacy.append(SummarySection(
                title: NSLocalizedString("summary.section.overview", comment: "Overview"),
                body: trimmedContent
            ))
        }
        let decisions = keyDecisions
        if !decisions.isEmpty {
            legacy.append(SummarySection(
                title: NSLocalizedString("summary.section.key_decisions", comment: "Key Decisions"),
                items: decisions
            ))
        }
        let actions = actionItems
        if !actions.isEmpty {
            legacy.append(SummarySection(
                title: NSLocalizedString("summary.section.action_items", comment: "Action Items"),
                items: actions
            ))
        }
        return legacy
    }

    var actionItems: [String] {
        get { (try? JSONDecoder().decode([String].self, from: actionItemsData)) ?? [] }
        set { actionItemsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var keyDecisions: [String] {
        get { (try? JSONDecoder().decode([String].self, from: keyDecisionsData)) ?? [] }
        set { keyDecisionsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var provider: AIProvider {
        get { AIProvider(rawValue: providerRaw) ?? .openAI }
        set { providerRaw = newValue.rawValue }
    }

    var model: String? {
        get {
            guard let modelRaw, !modelRaw.isEmpty else { return nil }
            return modelRaw
        }
        set { modelRaw = newValue }
    }
}
