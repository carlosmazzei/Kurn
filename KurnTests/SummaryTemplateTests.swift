//
//  SummaryTemplateTests.swift
//  KurnTests
//
//  Covers the template-driven summary prompt, the migration of legacy section
//  lists, and the Summary model's section storage.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct SummaryTemplateTests {

    // MARK: - Prompt

    @Test func systemPromptInjectsInstructionsAndTheMarkdownContract() {
        let template = SummaryTemplate.custom(
            name: "QA Review",
            instructions: "Focus on defects and test coverage, in sections Bugs and Coverage."
        )
        let prompt = SummaryPrompt.system(for: template)
        #expect(prompt.contains("Focus on defects and test coverage, in sections Bugs and Coverage."))
        #expect(prompt.contains("SAME LANGUAGE"))
        #expect(prompt.contains("\"## \" heading"))
        #expect(prompt.contains("📷 [12:34]"))
        #expect(!prompt.contains("JSON"))
    }

    @Test func systemPromptDescribesMarkdownCapabilities() {
        let prompt = SummaryPrompt.system(for: .general)
        // The renderer supports these blocks; the prompt must advertise them so
        // models actually emit them.
        #expect(prompt.contains("- [ ]"))
        #expect(prompt.contains("- [x]"))
        #expect(prompt.contains("table"))
        #expect(prompt.contains("\"> \""))
        #expect(prompt.contains("no code fence around it"))
    }

    @Test func builtInsNameTheirSectionsInTheInstructions() {
        #expect(SummaryTemplate.standup.instructions.contains("Done, Next and Blockers"))
        #expect(SummaryTemplate.outline.instructions.contains("Summary and Outline"))
    }

    // MARK: - Legacy section lists

    @Test func aStoredTemplateWithSectionsFoldsThemIntoTheInstructions() throws {
        let json = #"""
        {"id":"template-1","name":"QA","iconName":"doc.text","instructions":"Focus on defects.",
         "sections":["Bugs"," ","Coverage"],"isBuiltIn":false,"createdAt":0}
        """#
        let template = try JSONDecoder().decode(SummaryTemplate.self, from: Data(json.utf8))
        #expect(template.instructions.hasPrefix("Focus on defects.\n\n"))
        #expect(template.instructions.hasSuffix("Bugs; Coverage."))
        #expect(template.updatedAt == template.createdAt)
    }

    @Test func aTemplateWithoutSectionsDecodesUnchanged() throws {
        let json = #"{"id":"t","name":"n","iconName":"i","instructions":"Keep it short.","isBuiltIn":false,"createdAt":0}"#
        let template = try JSONDecoder().decode(SummaryTemplate.self, from: Data(json.utf8))
        #expect(template.instructions == "Keep it short.")
    }

    @Test func encodingKeepsAnEmptySectionListForOlderVersions() throws {
        let template = SummaryTemplate.custom(name: "n", instructions: "Keep it short.")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any]
        #expect((object?["sections"] as? [String]) == [])
        let decoded = try JSONDecoder().decode(SummaryTemplate.self, from: JSONEncoder().encode(template))
        #expect(decoded == template)
    }

    // MARK: - Description

    @Test func aWrittenDescriptionIsWhatTheListShows() {
        let template = SummaryTemplate.custom(
            name: "QA", instructions: "Focus on defects. Then coverage.", details: "  Bugs found and what is untested  "
        )
        #expect(template.summaryDescription == "Bugs found and what is untested")
    }

    @Test func withoutADescriptionACustomTemplateShowsItsFirstSentence() {
        let template = SummaryTemplate.custom(name: "QA", instructions: "Focus on defects. Then coverage.\nMore.")
        #expect(template.summaryDescription == "Focus on defects.")
        #expect(SummaryTemplate.firstSentence(of: "Line one\nLine two") == "Line one")
        #expect(SummaryTemplate.firstSentence(of: "总结会议。然后列出任务。") == "总结会议。")
        #expect(SummaryTemplate.firstSentence(of: "v1.2 rollout plan") == "v1.2 rollout plan")
    }

    @Test func aBuiltInDescribesItsPurposeUnlessTheUserWroteOne() {
        #expect(!SummaryTemplate.general.summaryDescription.isEmpty)
        var edited = SummaryTemplate.general
        edited.details = "Mine"
        #expect(edited.summaryDescription == "Mine")
    }

    @Test func theDescriptionSurvivesEncodingAndIsOptionalOnDecode() throws {
        let template = SummaryTemplate.custom(name: "n", instructions: "i", details: "d")
        let decoded = try JSONDecoder().decode(SummaryTemplate.self, from: JSONEncoder().encode(template))
        #expect(decoded.details == "d")
        let legacy = #"{"id":"t","name":"n","iconName":"i","instructions":"x","isBuiltIn":false,"createdAt":0}"#
        #expect(try JSONDecoder().decode(SummaryTemplate.self, from: Data(legacy.utf8)).details.isEmpty)
    }

    @Test func defaultTemplatesIncludeGeneralStandupInterview() throws {
        let ids = SummaryTemplate.defaultTemplates.map(\.id)
        #expect(ids.contains("general"))
        #expect(ids.contains("standup"))
        #expect(ids.contains("interview"))
        #expect(ids.contains("outline"))
        let allBuiltIn = SummaryTemplate.defaultTemplates.allSatisfy(\.isBuiltIn)
        #expect(allBuiltIn)
    }

    @Test func customTemplateIsNotBuiltInAndUsesGivenName() {
        let template = SummaryTemplate.custom(name: "My Template", instructions: "x")
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
