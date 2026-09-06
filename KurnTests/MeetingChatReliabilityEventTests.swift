//
//  MeetingChatReliabilityEventTests.swift
//  KurnTests
//
//  Proves the `ReliabilityEvent` seam end to end against `MeetingChatService`'s
//  two entry points, `answerAboutMeeting` and `answerAcrossLibrary`: the
//  "validation" stage for an empty question, and the "provider" stage for a
//  provider that fails to resolve. Mirrors
//  `DocumentGenerationReliabilityEventTests`/`DocumentGenerationServiceTests`'
//  explicit-`runID` filtering so this test isn't affected by other suites'
//  concurrently-reported "meeting_chat" events.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct MeetingChatReliabilityEventTests {

    // MARK: - Validation (empty question)

    @Test func emptyQuestionReportsOneFailedValidationEventForSingleMeeting() async {
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }
        let runID = OperationID()
        let service = MeetingChatService()

        await #expect(throws: AppError.self) {
            _ = try await service.answerAboutMeeting(
                question: "   ",
                history: [],
                transcriptText: "irrelevant transcript",
                candidates: [],
                provider: .openAI,
                model: "gpt-test",
                runID: runID
            )
        }

        let events = capture.recorded.filter { $0.operationID == runID }
        #expect(events.count == 1)
        #expect(events.first?.outcome == .failed)
        #expect(events.first?.stage == "validation")
        #expect(events.first?.code == "empty_question")
    }

    @Test func emptyQuestionReportsOneFailedValidationEventForLibrary() async {
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }
        let runID = OperationID()
        let service = MeetingChatService()

        await #expect(throws: AppError.self) {
            _ = try await service.answerAcrossLibrary(
                question: "",
                history: [],
                candidates: [],
                provider: .openAI,
                model: "gpt-test",
                runID: runID
            )
        }

        let events = capture.recorded.filter { $0.operationID == runID }
        #expect(events.count == 1)
        #expect(events.first?.outcome == .failed)
        #expect(events.first?.stage == "validation")
        #expect(events.first?.code == "empty_question")
    }

    // MARK: - Provider resolution

    /// `SystemLanguageModel.default.availability` can't be forced into a
    /// specific state here (CI's simulator has no Apple Intelligence), so this
    /// asserts the reliability report always agrees with whatever the live
    /// availability actually is, the same defensive shape
    /// `ProviderFactoryTests.summaryProviderForAppleOnDeviceMatchesLiveAvailability`
    /// uses, rather than assuming the provider unconditionally fails.
    @Test func appleOnDeviceProviderResolutionReliabilityMatchesAvailability() async {
        let reason = OnDeviceModelAvailability.unavailableReason
        let capture = ReliabilityEventCapture()
        capture.install()
        defer { capture.uninstall() }
        let runID = OperationID()
        let service = MeetingChatService()

        do {
            _ = try await service.answerAboutMeeting(
                question: "What was decided?",
                history: [],
                transcriptText: "",
                candidates: [],
                provider: .appleOnDevice,
                model: "",
                runID: runID
            )
            #expect(reason == nil, "call succeeded but availability reports unavailable: \(reason ?? "")")
            #expect(capture.recorded.filter { $0.operationID == runID }.isEmpty)
        } catch let error as AppError {
            guard case .onDeviceModelUnavailable = error else {
                Issue.record("expected onDeviceModelUnavailable, got \(error)")
                return
            }
            #expect(reason != nil, "call failed but availability reports available")
            let events = capture.recorded.filter { $0.operationID == runID }
            #expect(events.count == 1)
            #expect(events.first?.outcome == .failed)
            #expect(events.first?.stage == "provider")
        } catch {
            Issue.record("expected AppError, got \(error)")
        }
    }
}
