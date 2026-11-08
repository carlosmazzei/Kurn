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

    @Test func proseWithoutHeadingsIsOneUntitledSection() async throws {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(responseJSON("this is not json"))
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        let result = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
        #expect(result.sections.map(\.title) == [""])
        #expect(result.sections.first?.body == "this is not json")
    }

    @Test func blankSummaryContentThrowsDecodingError() async {
        MockURLProtocol.enqueue([
            MockURLProtocol.json(responseJSON("  \n  "))
        ])
        let provider = OpenAIProvider(apiKey: "secret", session: MockURLProtocol.session())

        do {
            _ = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
            Issue.record("expected a decoding error")
        } catch AppError.decodingError {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
