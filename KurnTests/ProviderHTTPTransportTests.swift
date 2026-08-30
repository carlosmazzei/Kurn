//
//  ProviderHTTPTransportTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {
    @Test func rateLimitIsRetriedThenSucceeds() async throws {
        // First a 429 with a short Retry-After, then a success — the shared retry
        // loop should transparently recover. Retry-After is honored, so the wait
        // is tiny and the test stays fast.
        MockURLProtocol.enqueue([
            .success(
                status: 429,
                body: Data(#"{"error":{"message":"slow down"}}"#.utf8),
                headers: ["Retry-After": "0.05"]
            ),
            MockURLProtocol.json(["choices": [["message": ["content": sectionsBody]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        let result = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
        #expect(result.sections.first?.title == "Recap")
        let requests = MockURLProtocol.capturedRequests
        #expect(requests.count == 2)
        let requestID = requests[0].value(forHTTPHeaderField: "X-Client-Request-Id")
        #expect(UUID(uuidString: requestID ?? "") != nil)
        #expect(requests[1].value(forHTTPHeaderField: "X-Client-Request-Id") == requestID)
    }

    @Test func ambiguousPOSTTimeoutIsNotRetried() async throws {
        MockURLProtocol.enqueue([
            .failure(URLError(.timedOut)),
            MockURLProtocol.json(["ok": true])
        ])
        var request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1")))
        request.httpMethod = "POST"

        do {
            _ = try await LLMHTTP.sendValidated(
                request,
                session: MockURLProtocol.session()
            )
            Issue.record("Expected ambiguousProviderResult")
        } catch AppError.ambiguousProviderResult {
        } catch {
            Issue.record("Unexpected ambiguous-result error: \(error)")
        }

        #expect(MockURLProtocol.capturedRequests.count == 1)
    }

    @Test func idempotentGETReusesIdentityAcrossRetry() async throws {
        MockURLProtocol.enqueue([
            .failure(URLError(.timedOut)),
            MockURLProtocol.json(["ok": true])
        ])
        let identity = UUID()
        var request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1")))
        request.httpMethod = "GET"

        _ = try await LLMHTTP.sendValidated(
            request,
            session: MockURLProtocol.session(),
            clock: ManualSleepClock(),
            context: HTTPExecutionContext(
                semantics: HTTPRequestSemantics(
                    identity: identity,
                    replaySafety: .idempotent,
                    correlationHeaderName: "X-Test-Request-Id"
                )
            )
        )

        let requests = MockURLProtocol.capturedRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "X-Test-Request-Id") == identity.uuidString
        })
    }

    /// Proves the `SleepClock` seam end to end against the one production
    /// call site that actually sleeps on the retry path: a 429 (with a
    /// server `Retry-After`, so the delay is exact rather than jittered)
    /// followed by a 200 completes with the final response, and the injected
    /// clock (which never really waits) recorded exactly that delay — in
    /// milliseconds, not real seconds. It remains on this suite type so its
    /// process-global `MockURLProtocol` state stays serialized with provider tests.
    @Test func sendValidatedBacksOffUsingInjectedClock() async throws {
        MockURLProtocol.enqueue([
            .success(status: 429, body: Data(), headers: ["Retry-After": "1"]),
            MockURLProtocol.json(["ok": true])
        ])
        let clock = ManualSleepClock()
        let request = URLRequest(url: try #require(URL(string: "https://example.com/v1")))

        let (data, response) = try await LLMHTTP.sendValidated(
            request, session: MockURLProtocol.session(), clock: clock
        )

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        let body = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
        #expect(body?["ok"] == true)
        #expect(clock.durations == [1])
    }

    @Test func responseBodyLargerThanPolicyIsRejected() async throws {
        MockURLProtocol.enqueue([
            .success(status: 200, body: Data([1, 2, 3, 4, 5]), headers: [:])
        ])
        let request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1")))

        do {
            _ = try await LLMHTTP.sendValidated(
                request,
                session: MockURLProtocol.session(),
                policy: HTTPPolicy(totalDeadline: 10, maxResponseBytes: 4)
            )
            Issue.record("Expected providerResponseTooLarge")
        } catch AppError.providerResponseTooLarge {
        } catch {
            Issue.record("Unexpected response-size error: \(error)")
        }
    }

    @Test func declaredResponseLengthIsRejectedBeforeBuffering() async throws {
        MockURLProtocol.enqueue([
            .success(
                status: 200,
                body: Data([1, 2, 3, 4, 5]),
                headers: ["Content-Length": "5"]
            )
        ])
        let request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1")))

        do {
            _ = try await LLMHTTP.sendValidated(
                request,
                session: MockURLProtocol.session(),
                policy: HTTPPolicy(totalDeadline: 10, maxResponseBytes: 4)
            )
            Issue.record("Expected providerResponseTooLarge")
        } catch AppError.providerResponseTooLarge {
        } catch {
            Issue.record("Unexpected declared-size error: \(error)")
        }
    }

    @Test func serverWaitBeyondPolicyFailsWithoutRetrying() async throws {
        MockURLProtocol.enqueue([
            .success(status: 429, body: Data(), headers: ["Retry-After": "2"]),
            MockURLProtocol.json(["ok": true])
        ])
        let clock = ManualSleepClock()
        let request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1")))

        do {
            _ = try await LLMHTTP.sendValidated(
                request,
                session: MockURLProtocol.session(),
                clock: clock,
                policy: HTTPPolicy(totalDeadline: 1, maxResponseBytes: 1_024)
            )
            Issue.record("Expected a total deadline timeout")
        } catch let AppError.apiError(status, _) {
            #expect(status == 429)
        } catch {
            Issue.record("Unexpected wait-budget error: \(error)")
        }

        #expect(clock.durations.isEmpty)
        #expect(MockURLProtocol.capturedRequests.count == 1)
    }

    @Test func streamedResponseCannotOutliveTotalDeadline() async throws {
        MockURLProtocol.enqueue([
            .success(status: 200, body: Data([1, 2, 3, 4, 5]), headers: [:])
        ])
        let clock = SteppingHTTPClock(step: 0.6)
        let request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1")))

        do {
            _ = try await LLMHTTP.sendValidated(
                request,
                session: MockURLProtocol.session(),
                clock: clock,
                policy: HTTPPolicy(totalDeadline: 2, maxResponseBytes: 1_024)
            )
            Issue.record("Expected streaming deadline timeout")
        } catch let AppError.networkError(error) {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("Unexpected streaming deadline error: \(error)")
        }
    }

    @Test func cancelledOperationDoesNotStartOrRetryARequest() async throws {
        MockURLProtocol.enqueue([MockURLProtocol.json(["ok": true])])
        let request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1")))

        let cancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await LLMHTTP.sendValidated(
                    request,
                    session: MockURLProtocol.session()
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(cancelled)
        #expect(MockURLProtocol.capturedRequests.isEmpty)
    }

    @Test func retryUsesTheRemainingDeadlineAsAttemptTimeout() async throws {
        MockURLProtocol.enqueue([
            .success(status: 429, body: Data(), headers: ["Retry-After": "1"]),
            MockURLProtocol.json(["ok": true])
        ])
        let clock = ManualSleepClock()
        var request = URLRequest(url: try #require(URL(string: "https://api.example.com/v1")))
        request.timeoutInterval = 10

        _ = try await LLMHTTP.sendValidated(
            request,
            session: MockURLProtocol.session(),
            clock: clock,
            policy: HTTPPolicy(totalDeadline: 3, maxResponseBytes: 1_024)
        )

        let attempts = MockURLProtocol.capturedRequests
        #expect(attempts.count == 2)
        #expect(attempts[0].timeoutInterval == 3)
        #expect(attempts[1].timeoutInterval == 2)
        #expect(clock.durations == [1])
    }
}

private final class SteppingHTTPClock: MonotonicSleepClock, @unchecked Sendable {
    private let lock = NSLock()
    private let step: TimeInterval
    private var currentTime: TimeInterval = 0

    init(step: TimeInterval) {
        self.step = step
    }

    var now: TimeInterval {
        lock.withLock {
            defer { currentTime += step }
            return currentTime
        }
    }

    func sleep(seconds: TimeInterval) async throws {
        lock.withLock {
            currentTime += seconds
        }
    }
}
