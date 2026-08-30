//
//  ProviderURLPolicyTests.swift
//  KurnTests
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {
    @Test(arguments: [
        "",
        "not a url",
        "/v1",
        "http://api.example.com/v1",
        "ftp://api.example.com/v1",
        "https://localhost/v1",
        "https://service.local/v1",
        "https://127.0.0.1/v1",
        "https://10.0.0.1/v1",
        "https://192.168.1.1/v1",
        "https://8.8.8.8/v1",
        "https://256.1.2.3/v1",
        "https://192.300.1.1/v1",
        "https://[::1]/v1",
        "https://user:pass@example.com/v1",
        "https://api.example.com:8443/v1",
        "https://api.example.com/v1?tenant=private",
        "https://api.example.com/v1#fragment",
        "https://api.example.com/v1/../internal",
        "https://api.example.com/v1%2F..%2Finternal",
        "https://intranet/v1"
    ])
    func unsafeProviderBaseURLIsRejected(_ baseURLString: String) {
        #expect(!LLMHTTP.isValidBaseURL(baseURLString))
        #expect(LLMHTTP.endpoint(baseURLString: baseURLString, path: "models") == nil)
    }

    @Test(arguments: [
        "https://api.openai.com/v1",
        "https://api.anthropic.com/v1",
        "https://generativelanguage.googleapis.com/v1beta",
        "https://gateway.example.com:443/openai/v1"
    ])
    func publicHTTPSProviderBaseURLIsAccepted(_ baseURLString: String) {
        #expect(LLMHTTP.isValidBaseURL(baseURLString))
    }

    @Test func endpointPreservesTheValidatedBasePath() throws {
        let endpoint = try #require(LLMHTTP.endpoint(
            baseURLString: "https://gateway.example.com/openai/v1/",
            path: "/chat/completions"
        ))
        #expect(endpoint.absoluteString == "https://gateway.example.com/openai/v1/chat/completions")
    }

    @Test(arguments: ["../admin", "%2e%2e/admin", "v1\\..\\admin"])
    func unsafeEndpointPathIsRejected(_ path: String) {
        #expect(LLMHTTP.endpoint(baseURLString: "https://api.example.com/v1", path: path) == nil)
    }

    @Test func sameOriginRedirectIsAllowed() throws {
        let approved = try #require(URL(string: "https://api.example.com/v1/messages"))
        let proposedURL = try #require(URL(string: "https://api.example.com/v2/messages"))
        let proposed = URLRequest(url: proposedURL)

        let redirected = LLMHTTP.redirectRequest(
            approvedURL: approved,
            proposedRequest: proposed
        )

        #expect(redirected?.url == proposedURL)
    }

    @Test func explicitDefaultPortIsTheSameOrigin() throws {
        let approved = try #require(URL(string: "https://api.example.com/v1"))
        let proposed = URLRequest(
            url: try #require(URL(string: "https://api.example.com:443/v2"))
        )
        #expect(LLMHTTP.redirectRequest(approvedURL: approved, proposedRequest: proposed) != nil)
    }

    @Test(arguments: [
        "https://other.example.com/v2",
        "http://api.example.com/v2",
        "https://api.example.com:444/v2",
        "https://user@api.example.com/v2"
    ])
    func crossOriginRedirectIsRejected(_ destination: String) throws {
        let approved = try #require(URL(string: "https://api.example.com/v1"))
        let proposed = URLRequest(url: try #require(URL(string: destination)))
        #expect(LLMHTTP.redirectRequest(approvedURL: approved, proposedRequest: proposed) == nil)
    }

    @Test func invalidCustomProviderCannotFallBackForSummaryOrTranscription() async {
        MockURLProtocol.enqueue([])
        let configured = AIProvider.custom(
            displayName: "Broken",
            kind: .openAICompatible,
            baseURLString: "not a url"
        )
        let provider = OpenAIProvider(
            provider: configured,
            apiKey: "secret",
            session: MockURLProtocol.session()
        )

        do {
            _ = try await provider.summarize(systemPrompt: "s", userPrompt: "u")
            Issue.record("Expected invalidProviderURL for summary")
        } catch AppError.invalidProviderURL {
        } catch {
            Issue.record("Unexpected summary error: \(error)")
        }

        do {
            _ = try await provider.transcribe(
                audioData: Data([1]), fileName: "clip.m4a", language: .english
            )
            Issue.record("Expected invalidProviderURL for transcription")
        } catch AppError.invalidProviderURL {
        } catch {
            Issue.record("Unexpected transcription error: \(error)")
        }

        #expect(MockURLProtocol.capturedRequests.isEmpty)
    }

    @Test func invalidCustomProviderCannotListModels() async {
        MockURLProtocol.enqueue([])
        let provider = AIProvider.custom(
            displayName: "Broken",
            kind: .openAICompatible,
            baseURLString: "https://localhost/v1"
        )
        let service = ProviderModelsService(
            session: MockURLProtocol.session(),
            apiKey: "secret"
        )

        do {
            _ = try await service.models(for: provider)
            Issue.record("Expected invalidProviderURL")
        } catch AppError.invalidProviderURL {
        } catch {
            Issue.record("Unexpected models error: \(error)")
        }

        #expect(MockURLProtocol.capturedRequests.isEmpty)
    }
}
