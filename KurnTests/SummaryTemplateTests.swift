//
//  SummaryTemplateTests.swift
//  KurnTests
//
//  Covers the template-driven summary prompt and the Summary model's section
//  storage.
//

import Testing
@testable import Kurn

struct SummaryTemplateTests {

    // MARK: - Prompt

    @Test func systemPromptInjectsInstructionsAndSections() {
        let template = SummaryTemplate.custom(
            name: "QA Review",
            instructions: "Focus on defects and test coverage.",
            sections: ["Bugs", "Coverage"]
        )
        let prompt = SummaryPrompt.system(for: template)
        #expect(prompt.contains("Focus on defects and test coverage."))
        #expect(prompt.contains("- Bugs"))
        #expect(prompt.contains("- Coverage"))
        #expect(prompt.contains("\"sections\""))
        #expect(prompt.contains("SAME LANGUAGE"))
    }

    @Test func systemPromptOmitsSectionListWhenNoSections() {
        let template = SummaryTemplate.custom(
            name: "Freeform",
            instructions: "Summarize however fits best.",
            sections: []
        )
        let prompt = SummaryPrompt.system(for: template)
        #expect(prompt.contains("Summarize however fits best."))
        #expect(!prompt.contains("Organize the summary into sections"))
    }

    @Test func defaultTemplatesIncludeGeneralStandupInterview() throws {
        let ids = SummaryTemplate.defaultTemplates.map(\.id)
        #expect(ids.contains("general"))
        #expect(ids.contains("standup"))
        #expect(ids.contains("interview"))
        let allBuiltIn = SummaryTemplate.defaultTemplates.allSatisfy(\.isBuiltIn)
        #expect(allBuiltIn)
    }

    @Test func customTemplateIsNotBuiltInAndUsesGivenName() {
        let template = SummaryTemplate.custom(
            name: "My Template",
            instructions: "x",
            sections: []
        )
        #expect(!template.isBuiltIn)
        #expect(template.displayName == "My Template")
        #expect(template.id.hasPrefix("template-"))
    }

    // MARK: - Summary sections

    @Test func sectionsRoundTripThroughJSONStorage() {
        let summary = Summary(
            sections: [SummarySection(title: "T", body: "b", items: ["i"])],
            provider: .openAI
        )
        #expect(summary.sections.count == 1)
        #expect(summary.sections.first?.title == "T")
        #expect(summary.sections.first?.body == "b")
        #expect(summary.sections.first?.items == ["i"])
    }
}
