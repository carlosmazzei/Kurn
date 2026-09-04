//
//  DocumentGenerationServiceTests.swift
//  KurnTests
//
//  The deterministic half of `DocumentGenerationService`: prompt validation,
//  source rendering and block packing for the staged path, and title
//  extraction. The LLM round trip itself is exercised in the provider suites;
//  the reliability-event seam in `DocumentGenerationReliabilityEventTests`.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct DocumentGenerationServiceTests {

    private func source(
        title: String = "Weekly sync",
        transcript: String,
        id: UUID = UUID()
    ) -> DocumentTranscriptSource {
        DocumentTranscriptSource(
            meetingID: id,
            title: title,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            transcript: transcript
        )
    }

    // MARK: - Validation

    @Test func blankPromptFailsBeforeTouchingAnyProvider() async {
        let capture = ReliabilityEventCapture()
        ReliabilityLog.handler = { capture.record($0) }
        defer { ReliabilityLog.handler = nil }
        let runID = OperationID()

        await #expect(throws: AppError.self) {
            _ = try await DocumentGenerationService().generate(
                sources: [source(transcript: "Alice: hello")],
                prompt: "  \n\t ",
                provider: .openAI,
                model: "gpt-test",
                runID: runID
            )
        }

        let events = capture.recorded.filter { $0.operationID == runID }
        #expect(events.count == 1)
        #expect(events.first?.stage == "validation")
        #expect(events.first?.code == "empty_prompt")
    }

    @Test func emptyPromptErrorCarriesTheDocumentGenerationLogCode() async {
        do {
            _ = try await DocumentGenerationService().generate(
                sources: [source(transcript: "x")], prompt: "", provider: .openAI, model: "m"
            )
            Issue.record("expected an error")
        } catch let error as AppError {
            #expect(error.logCode == "document_generation")
        } catch {
            Issue.record("unexpected error type \(error)")
        }
    }

    // MARK: - Rendering

    @Test func renderWrapsEachSourceInAMeetingElementWithMetadata() {
        let id = UUID()
        let rendered = DocumentGenerationService.render([
            source(title: "Kickoff", transcript: "Bob: let's start", id: id)
        ])

        #expect(rendered.hasPrefix("<meeting id=\"\(id.uuidString)\">"))
        #expect(rendered.contains("Title: Kickoff"))
        #expect(rendered.contains("Date: 2023-11-14T22:13:20Z"))
        #expect(rendered.contains("Bob: let's start"))
        #expect(rendered.hasSuffix("</meeting>"))
    }

    @Test func renderJoinsSourcesWithABlankLineAndPreservesOrder() throws {
        let rendered = DocumentGenerationService.render([
            source(title: "First", transcript: "a"),
            source(title: "Second", transcript: "b")
        ])
        let first = try #require(rendered.range(of: "Title: First"))
        let second = try #require(rendered.range(of: "Title: Second"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(rendered.contains("</meeting>\n\n<meeting"))
    }

    @Test func renderOfNoSourcesIsEmpty() {
        #expect(DocumentGenerationService.render([]).isEmpty)
    }

    // MARK: - Block packing

    @Test func smallSourcesArePackedTogetherIntoOneBlock() {
        let blocks = DocumentGenerationService.renderBlocks(
            [source(transcript: "short one"), source(transcript: "short two")],
            maxChars: 2_000
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].contains("short one"))
        #expect(blocks[0].contains("short two"))
    }

    @Test func oversizedSourceIsSplitWithMetadataRepeatedInEveryPart() {
        let id = UUID()
        let lines = (1...60).map { "Speaker \($0 % 3): line number \($0) with some filler words" }
        let transcript = lines.joined(separator: "\n")
        let blocks = DocumentGenerationService.renderBlocks(
            [source(title: "Long", transcript: transcript, id: id)],
            maxChars: 800
        )

        #expect(blocks.count > 1)
        for (index, block) in blocks.enumerated() {
            #expect(block.contains("<meeting id=\"\(id.uuidString)\">"))
            #expect(block.contains("Title: Long"))
            #expect(block.contains("Transcript part \(index + 1) of \(blocks.count):"))
        }
        // No line is cut in half: every original line appears whole somewhere.
        let joined = blocks.joined(separator: "\n")
        for line in lines {
            #expect(joined.contains(line))
        }
    }

    @Test func packingNeverSplitsAWholeMeetingAcrossBlocks() {
        let medium = String(repeating: "word ", count: 80)
        let blocks = DocumentGenerationService.renderBlocks(
            [source(title: "A", transcript: medium), source(title: "B", transcript: medium), source(title: "C", transcript: medium)],
            maxChars: 1_100
        )
        #expect(blocks.count >= 2)
        for block in blocks {
            let opens = block.components(separatedBy: "<meeting id=").count - 1
            let closes = block.components(separatedBy: "</meeting>").count - 1
            #expect(opens == closes)
        }
    }

    // MARK: - Title extraction

    @Test func titleComesFromTheFirstHeadingWithMarkdownStripped() {
        #expect(
            DocumentGenerationService.extractTitle(
                from: "## **Q3 Roadmap**\n\nBody text", fallbackPrompt: "ignored"
            ) == "Q3 Roadmap"
        )
        #expect(
            DocumentGenerationService.extractTitle(
                from: "# Plain title\nmore", fallbackPrompt: "ignored"
            ) == "Plain title"
        )
    }

    @Test func titleUsesFirstLineEvenWithoutAHeadingMarker() {
        #expect(
            DocumentGenerationService.extractTitle(from: "Decision log\n- a", fallbackPrompt: "x") == "Decision log"
        )
    }

    @Test func overlongFirstLineFallsBackToThePromptTruncatedTo80Chars() {
        let longLine = String(repeating: "x", count: 121)
        let prompt = String(repeating: "p", count: 100) + "\nsecond line"
        let title = DocumentGenerationService.extractTitle(from: longLine, fallbackPrompt: prompt)
        #expect(title == String(repeating: "p", count: 80))
    }

    @Test func emptyMarkdownFallsBackToFirstPromptLine() {
        #expect(
            DocumentGenerationService.extractTitle(from: "", fallbackPrompt: "\n  Write minutes\nextra") == "Write minutes"
        )
    }

    @Test func decorationOnlyFirstLineFallsBackToPrompt() {
        #expect(DocumentGenerationService.extractTitle(from: "** **\nbody", fallbackPrompt: "fallback") == "fallback")
    }
}
