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
        capture.install()
        defer { capture.uninstall() }

        let service = DocumentGenerationService()
        await #expect(throws: AppError.self) {
            _ = try await service.generate(
                sources: [],
                prompt: "Summarize the decisions",
                provider: .openAI,
                model: "gpt-test"
            )
        }

        // The handler is process-global and suites run in parallel, so only
        // this operation's events are this test's to count.
        let captured = capture.recorded.filter { $0.operation == "document_generation" }
        #expect(captured.count == 1)
        #expect(captured.first?.outcome == .failed)
        #expect(captured.first?.stage == "validation")
        #expect(captured.first?.code == "no_transcripts")
    }
}
