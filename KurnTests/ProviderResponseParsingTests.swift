//
//  ProviderResponseParsingTests.swift
//  KurnTests
//

import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {
    @Test func apiErrorSurfacesStatusAndVendorMessage() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["error": ["message": "bad key"]], status: 401)
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        do {
            _ = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
            Issue.record("expected an error")
        } catch let AppError.apiError(status, message) {
            #expect(status == 401)
            #expect(message == "bad key")
        }
    }

    @Test func malformedSummaryContentThrowsDecodingError() async {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(["choices": [["message": ["content": "this is not json"]]]])
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        await #expect(throws: AppError.self) {
            _ = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
        }
    }
}
