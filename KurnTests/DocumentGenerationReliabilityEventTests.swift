//
//  DocumentGenerationReliabilityEventTests.swift
//  KurnTests
//
//  Proves the `ReliabilityEvent` seam end to end against real production
//  code: `DocumentGenerationService`'s existing "no transcripts" validation
//  guard now reports through `ReliabilityLog` instead of an ad hoc log line,
//  and this installs a capturing handler to confirm exactly that.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct DocumentGenerationReliabilityEventTests {

    @Test func emptySourcesReportsOneFailedValidationEvent() async {
        let capture = ReliabilityEventCapture()
        ReliabilityLog.handler = { capture.record($0) }
        defer { ReliabilityLog.handler = nil }

        let service = DocumentGenerationService()
        await #expect(throws: AppError.self) {
            _ = try await service.generate(
                sources: [],
                prompt: "Summarize the decisions",
                provider: .openAI,
                model: "gpt-test"
            )
        }

        let captured = capture.recorded
        #expect(captured.count == 1)
        #expect(captured.first?.outcome == .failed)
        #expect(captured.first?.stage == "validation")
        #expect(captured.first?.code == "no_transcripts")
        #expect(captured.first?.operation == "document_generation")
    }
}
