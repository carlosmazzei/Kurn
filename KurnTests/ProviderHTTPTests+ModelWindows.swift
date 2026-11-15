//
//  ProviderHTTPTests+ModelWindows.swift
//  KurnTests
//
//  The context windows a `/models` listing reports, remembered for
//  `ContextBudget.resolve`. An extension of `ProviderHTTPTests` rather than
//  its own suite: it scripts the process-global `MockURLProtocol`, and
//  `.serialized` only orders tests within one suite.
//

import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {

    @Test func anthropicPagesPreserveInputAndOutputLimits() async throws {
        let suite = "ProviderHTTPTests.anthropic.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["data": [["id": "claude-first", "max_input_tokens": 200_000, "max_tokens": 8_192]],
                                  "has_more": true, "last_id": "claude-first"]),
            MockURLProtocol.json(["data": [["id": "claude-second", "max_input_tokens": 1_000_000, "max_tokens": 128_000]],
                                  "has_more": false])
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "secret", contextWindows: windows)
        #expect(try await service.models(for: .anthropic) == ["claude-first", "claude-second"])
        let limits = try #require(windows.limits(for: .anthropic, model: "claude-second"))
        #expect(limits.contextWindowTokens == 1_000_000)
        #expect(limits.maxOutputTokens == 128_000)
        #expect(limits.limitKind == .input)
        #expect(MockURLProtocol.capturedRequests.count == 2)
        #expect(MockURLProtocol.lastRequest?.url?.query == "after_id=claude-first")
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test func googlePagesDoNotCollapseVersionedModelsIntoTheBaseModel() async throws {
        let suite = "ProviderHTTPTests.google-pages.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["models": [["name": "models/gemini-test-001", "baseModelId": "gemini-test",
                                               "inputTokenLimit": 64_000, "outputTokenLimit": 2_000,
                                               "supportedGenerationMethods": ["generateContent"]]], "nextPageToken": "page2"]),
            MockURLProtocol.json(["models": [["name": "models/gemini-test-002", "baseModelId": "gemini-test",
                                               "inputTokenLimit": 128_000, "outputTokenLimit": 4_000,
                                               "supportedGenerationMethods": ["generateContent"]]]])
        ])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "secret", contextWindows: windows)
        #expect(try await service.models(for: .google) == ["gemini-test-001", "gemini-test-002"])
        #expect(windows.limits(for: .google, model: "gemini-test-001")?.contextWindowTokens == 64_000)
        #expect(windows.limits(for: .google, model: "gemini-test-002")?.maxOutputTokens == 4_000)
        #expect(windows.limits(for: .google, model: "gemini-test") == nil)
        #expect(MockURLProtocol.lastRequest?.url?.query == "pageToken=page2")
    }

    @Test func cyclicOrMissingModelPageCursorsFailWithoutLooping() async throws {
        let response: [String: Any] = ["data": [["id": "model"]], "has_more": true, "last_id": "same"]
        MockURLProtocol.enqueue([MockURLProtocol.json(response), MockURLProtocol.json(response)])
        let service = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "secret")
        await #expect(throws: AppError.self) { try await service.models(for: .anthropic) }
        #expect(MockURLProtocol.capturedRequests.count == 2)
        MockURLProtocol.enqueue([MockURLProtocol.json(["data": [["id": "model"]], "has_more": true])])
        await #expect(throws: AppError.self) { try await service.models(for: .anthropic) }
        #expect(MockURLProtocol.capturedRequests.count == 1)
    }

    @Test func reportedContextWindowsAreRemembered() async throws {
        let suite = "ProviderHTTPTests.windows.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)

        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "data": [
                    ["id": "llama-3.3-70b-versatile", "active": true, "context_window": 131_072],
                    ["id": "router/model", "context_length": 65_536],
                    ["id": "odd-model", "context_window": "big"],
                    ["id": "plain-model"]
                ]
            ])
        ])
        let groq = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "groq-secret", contextWindows: windows)
        let models = try await groq.models(for: .groq)
        #expect(models.contains("odd-model"))
        #expect(windows.limits(for: .groq, model: "llama-3.3-70b-versatile")?.contextWindowTokens == 131_072)
        #expect(windows.limits(for: .groq, model: "router/model")?.contextWindowTokens == 65_536)
        #expect(windows.limits(for: .groq, model: "odd-model") == nil)
        #expect(windows.limits(for: .groq, model: "plain-model") == nil)

        MockURLProtocol.enqueue([
            MockURLProtocol.json([
                "models": [
                    [
                        "name": "models/gemini-2.5-pro",
                        "supportedGenerationMethods": ["generateContent"],
                        "inputTokenLimit": 1_048_576
                    ]
                ]
            ])
        ])
        let google = ProviderModelsService(session: MockURLProtocol.session(), apiKey: "gk", contextWindows: windows)
        _ = try await google.models(for: .google)
        #expect(windows.limits(for: .google, model: "gemini-2.5-pro")?.contextWindowTokens == 1_048_576)
    }
}
