import Foundation
import Testing
@testable import AgentHarness

/// NH07 session-owned retries: bounded, cancellable and never after visible text.
@Suite struct AgentRetryPolicyTests {
    struct Transient: AgentTransientError, Equatable {
        var retryAfterSeconds: Double?
        var isTransient: Bool { true }
    }

    struct Permanent: Error, Equatable {}

    /// Records each wait instead of sleeping.
    actor Waits {
        var values: [Double] = []
        func add(_ seconds: Double) { values.append(seconds) }
    }

    /// Streams some text, then fails.
    actor StreamsThenFails: AgentModel {
        var requests = 0
        func streamTurn(_ request: AgentTurnRequest,
                        onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
            requests += 1
            onEvent(.textDelta("Partial"))
            throw Transient()
        }
    }

    private func policy(_ waits: Waits, attempts: Int = 3) -> AgentRetryPolicy {
        AgentRetryPolicy(maxAttempts: attempts, baseDelaySeconds: 1, maxDelaySeconds: 10, maxWaitSeconds: 15,
                         sleep: { await waits.add($0) })
    }

    @Test func delaysBackOffHonourRetryAfterAndStayBounded() {
        let policy = AgentRetryPolicy(maxAttempts: 4, baseDelaySeconds: 1, maxDelaySeconds: 10, maxWaitSeconds: 12)
        #expect(policy.delay(after: Transient(), failedAttempts: 1, waited: 0) == 1)
        #expect(policy.delay(after: Transient(), failedAttempts: 2, waited: 1) == 2)
        #expect(policy.delay(after: Transient(), failedAttempts: 3, waited: 3) == 4)
        // Attempts exhausted, a total wait that would pass the bound, or a long Retry-After: no retry.
        #expect(policy.delay(after: Transient(), failedAttempts: 4, waited: 0) == nil)
        #expect(policy.delay(after: Transient(), failedAttempts: 3, waited: 9) == nil)
        #expect(policy.delay(after: Transient(retryAfterSeconds: 7), failedAttempts: 1, waited: 0) == 7)
        #expect(policy.delay(after: Transient(retryAfterSeconds: 30), failedAttempts: 1, waited: 0) == nil)
        // Only transient failures are retried.
        #expect(policy.delay(after: Permanent(), failedAttempts: 1, waited: 0) == nil)
        #expect(policy.delay(after: CancellationError(), failedAttempts: 1, waited: 0) == nil)
        #expect(AgentRetryPolicy.none.delay(after: Transient(), failedAttempts: 1, waited: 0) == nil)
    }

    @Test func aTransientFailureIsSentAgainAsANewRequest() async throws {
        let waits = Waits()
        let model = ResultScriptedAgentModel([.failure(Transient()), .failure(Transient(retryAfterSeconds: 3)),
                                             .success(AgentTurnResponse(text: "Answer"))])
        let capture = DiagnosticCapture()
        let harness = NativeHarness(model: model, retryPolicy: policy(waits), diagnosticSink: { capture.record($0) })
        let events = try await agentEvents(harness)

        #expect(try agentOutcome(events).finalText == "Answer")
        let requests = await model.requests
        #expect(requests.count == 3)
        // Each attempt is its own request.
        #expect(Set(requests.compactMap { $0.identity?.id }).count == 3)
        #expect(await waits.values == [1, 3])
        let scheduled = capture.events.filter { $0.kind == .requestRetryScheduled }
        #expect(scheduled.map { $0.metrics[.requestAttempt] } == [1, 2])
        #expect(scheduled.map { $0.metrics[.retryDelayMs] } == [1_000, 3_000])
    }

    @Test func aHostsRetryAfterHintShapesTheWaitAndNothingElse() async throws {
        let policy = AgentRetryPolicy(maxAttempts: 3, baseDelaySeconds: 1, maxDelaySeconds: 10, maxWaitSeconds: 15)
        #expect(policy.delay(after: AgentRetryAfter(Transient(), seconds: 6), failedAttempts: 1, waited: 0) == 6)
        #expect(policy.delay(after: AgentRetryAfter(Transient(), seconds: 30), failedAttempts: 1, waited: 0) == nil)
        // A hint never makes a permanent failure retryable.
        #expect(policy.delay(after: AgentRetryAfter(Permanent(), seconds: 2), failedAttempts: 1, waited: 0) == nil)

        let waits = Waits()
        let model = ResultScriptedAgentModel([.failure(AgentRetryAfter(Transient(), seconds: 4)),
                                             .failure(AgentRetryAfter(Permanent(), seconds: 1)),
                                             .success(AgentTurnResponse(text: "Unused"))])
        // The run fails with the host's own error, never the wrapper.
        await #expect(throws: Permanent.self) {
            try await agentEvents(NativeHarness(model: model, retryPolicy: self.policy(waits)))
        }
        #expect(await waits.values == [4])
        #expect(await model.requests.count == 2)
    }

    @Test func attemptsAreBounded() async throws {
        let waits = Waits()
        let model = ResultScriptedAgentModel([.failure(Transient()), .failure(Transient()), .failure(Transient()),
                                             .success(AgentTurnResponse(text: "Unused"))])
        await #expect(throws: Transient.self) {
            try await agentEvents(NativeHarness(model: model, retryPolicy: policy(waits)))
        }
        #expect(await model.requests.count == 3)
        #expect(await waits.values.count == 2)
    }

    @Test func permanentFailuresAndVisibleTextAreNeverRetried() async throws {
        let waits = Waits()
        let permanent = ResultScriptedAgentModel([.failure(Permanent()), .success(AgentTurnResponse(text: "Unused"))])
        await #expect(throws: Permanent.self) {
            try await agentEvents(NativeHarness(model: permanent, retryPolicy: policy(waits)))
        }
        #expect(await permanent.requests.count == 1)
        // Two generations are never joined: text already shown ends the request.
        let streamed = StreamsThenFails()
        await #expect(throws: Transient.self) {
            try await agentEvents(NativeHarness(model: streamed, retryPolicy: policy(waits)))
        }
        #expect(await streamed.requests == 1)
        #expect(await waits.values.isEmpty)
    }

    @Test func cancellingDuringTheWaitStartsNoOtherAttempt() async throws {
        let gate = SessionTestGate()
        let model = ResultScriptedAgentModel([.failure(Transient()), .success(AgentTurnResponse(text: "Unused"))])
        let blocking = AgentRetryPolicy(maxAttempts: 3, sleep: { _ in
            await gate.block()
            try Task.checkCancellation()
        })
        let handle = NativeHarness(model: model, retryPolicy: blocking)
            .start(systemPrompt: "", history: [], prompt: "Q", tools: [])
        await gate.waitUntilEntered()
        handle.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await handle.result() }
        #expect(await model.requests.count == 1)
    }
}
