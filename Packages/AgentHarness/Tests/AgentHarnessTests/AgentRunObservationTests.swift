import Foundation
import Testing
@testable import AgentHarness

/// A host presentation reducer that rebuilds a timeline from events needs every event, while
/// the default owned observation is deliberately lossy. Both still leave execution to the owner.
@Suite struct AgentRunObservationTests {
    actor Chatty: AgentModel {
        let deltas: Int
        init(deltas: Int) { self.deltas = deltas }
        func streamTurn(_ request: AgentTurnRequest, onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
            for _ in 0..<deltas { onEvent(.textDelta("x")) }
            return AgentTurnResponse(text: String(repeating: "x", count: deltas))
        }
    }

    private func deltaCount(_ observation: AgentRunObservation) async throws -> Int {
        let run = NativeHarness(model: Chatty(deltas: 300))
            .start(systemPrompt: "", history: [], prompt: "Q", tools: [], observation: observation)
        // The producer finishes before anyone reads, so only the buffer decides what survives.
        _ = try await run.result()
        var count = 0
        for try await event in run.events { if case .textDelta = event { count += 1 } }
        return count
    }

    @Test func completeObservationKeepsEveryEventWhileBoundedKeepsTheNewest() async throws {
        #expect(try await deltaCount(.complete) == 300)
        #expect(try await deltaCount(.bounded) < 300)
    }

    @Test func cancellingACompleteObserverDoesNotCancelTheRun() async throws {
        let run = NativeHarness(model: Chatty(deltas: 3))
            .start(systemPrompt: "", history: [], prompt: "Q", tools: [], observation: .complete)
        let observer = Task { for try await _ in run.events {} }
        observer.cancel()
        _ = await observer.result
        let outcome = try await run.result()
        #expect(outcome.finalText == "xxx")
    }
}
