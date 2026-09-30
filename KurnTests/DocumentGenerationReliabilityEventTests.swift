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

        let runID = OperationID()
        let service = DocumentGenerationService()
        await #expect(throws: AppError.self) {
            _ = try await service.generate(
                sources: [],
                prompt: "Summarize the decisions",
                provider: .openAI,
                model: "gpt-test",
                runID: runID
            )
        }

        // The handler is process-global and suites run in parallel, so only
        // this run's events are this test's to count. Filtering by operation
        // name alone picked up `DocumentGenerationServiceTests`' concurrent
        // "empty_prompt" event.
        let captured = capture.recorded.filter { $0.operationID == runID }
        #expect(captured.count == 1)
        #expect(captured.first?.outcome == .failed)
        #expect(captured.first?.stage == "validation")
        #expect(captured.first?.code == "no_transcripts")
    }
}
