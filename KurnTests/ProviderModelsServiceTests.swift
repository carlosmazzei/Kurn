//
//  ProviderModelsServiceTests.swift
//  KurnTests
//
//  Exercises ProviderModelsService.models(for:) through MockURLProtocol and the
//  real Keychain (same pattern as ProviderFactoryTests), focused on confirming
//  Gemini's API key is sent as a header rather than a URL query parameter.
//

import Foundation
import Testing
@testable import Kurn

@Suite(.serialized)
struct ProviderModelsServiceTests {

    @discardableResult
    private func withKey<R>(_ key: KeychainKey, value: String, _ body: () async throws -> R) async rethrows -> R {
        let original = KeychainManager.shared.get(key)
        KeychainManager.shared.set(value, for: key)
        defer {
            if let original { KeychainManager.shared.set(original, for: key) } else { KeychainManager.shared.delete(key) }
        }
        return try await body()
    }

    @Test func googleModelsSendsKeyHeaderNotQuery() async throws {
        try await withKey(.google, value: "gk") {
            MockURLProtocol.enqueue([
                MockURLProtocol.json([
                    "models": [
                        [
                            "name": "models/gemini-1.5-pro",
                            "baseModelId": NSNull(),
                            "supportedGenerationMethods": ["generateContent"]
                        ]
                    ]
                ])
            ])
            let service = ProviderModelsService(session: MockURLProtocol.session())
            let models = try await service.models(for: .google)
            #expect(models.contains("gemini-1.5-pro"))

            let request = try #require(MockURLProtocol.lastRequest)
            #expect(request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "gk")
        }
    }
}
