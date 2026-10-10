//
//  ProviderHTTPTests+ModelWindows.swift
//  KurnTests
//
//  The context windows a `/models` listing reports, remembered for
//  `ContextBudget.resolve`. An extension of `ProviderHTTPTests` rather than
//  its own suite: it scripts the process-global `MockURLProtocol`, and
//  `.serialized` only orders tests within one suite.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {

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
        #expect(windows.window(providerID: AIProvider.groq.id, model: "llama-3.3-70b-versatile") == 131_072)
        #expect(windows.window(providerID: AIProvider.groq.id, model: "router/model") == 65_536)
        #expect(windows.window(providerID: AIProvider.groq.id, model: "odd-model") == nil)
        #expect(windows.window(providerID: AIProvider.groq.id, model: "plain-model") == nil)

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
        #expect(windows.window(providerID: AIProvider.google.id, model: "gemini-2.5-pro") == 1_048_576)
    }
}
