import AgentHarness
import Foundation
import KurnCore
import Testing
@testable import Kurn

extension ProviderHTTPTests {
    @Test func selectedAnthropicAliasUsesDetailAndCachesTheCanonicalModel() async throws {
        let suite = "ProviderHTTPTests.selected.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        MockURLProtocol.enqueue([MockURLProtocol.json(["id": "claude-canonical", "max_input_tokens": 96_000, "max_tokens": 8_192])])
        let service = ProviderModelMetadataService(session: MockURLProtocol.session(), apiKey: "secret",
                                                   windows: windows, coordinator: ProviderMetadataCoordinator())
        #expect(try await service.refresh(provider: .anthropic, model: "claude-alias") == .fetched)
        #expect(windows.limits(for: .anthropic, model: "claude-alias")?.contextWindowTokens == 96_000)
        #expect(windows.limits(for: .anthropic, model: "claude-canonical")?.maxOutputTokens == 8_192)
        // The resolved alias qualifies the run's capability snapshot (C04).
        #expect(windows.reportedCapabilities(for: .anthropic, model: "claude-alias")?.canonicalModelID == "claude-canonical")
        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.url?.path == "/v1/models/claude-alias")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.timeoutInterval <= 8)
        #expect(try await service.refresh(provider: .anthropic, model: "claude-alias") == .cacheFresh)
        #expect(MockURLProtocol.capturedRequests.count == 1)
        #expect(!windows.resolution(for: .anthropic, model: "claude-alias", metadataRefresh: .fetched).isCached)
    }

    @Test func cachedLimitsWithoutACapabilityCheckStillAskTheDetailRoute() async throws {
        let suite = "ProviderHTTPTests.capabilityCheck.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        windows.recordLimits(["claude-alias": AgentModelLimits(contextWindowTokens: 96_000, maxOutputTokens: 8_192)],
                             provider: .anthropic)
        #expect(windows.hasFreshCompleteLimits(for: .anthropic, model: "claude-alias"))
        MockURLProtocol.enqueue([MockURLProtocol.json(["id": "claude-alias", "max_input_tokens": 96_000, "max_tokens": 8_192])])
        let service = ProviderModelMetadataService(session: MockURLProtocol.session(), apiKey: "secret",
                                                   windows: windows, coordinator: ProviderMetadataCoordinator())
        #expect(try await service.refresh(provider: .anthropic, model: "claude-alias") == .fetched)
        #expect(MockURLProtocol.capturedRequests.count == 1)
        // No alias to report, but the check is recorded and not repeated while fresh.
        #expect(windows.reportedCapabilities(for: .anthropic, model: "claude-alias")?.canonicalModelID == nil)
        #expect(try await service.refresh(provider: .anthropic, model: "claude-alias") == .cacheFresh)
        #expect(MockURLProtocol.capturedRequests.count == 1)
    }

    @Test func selectedGoogleAliasPreservesVersionAndUsesHeaderAuthentication() async throws {
        let suite = "ProviderHTTPTests.selectedGoogle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        MockURLProtocol.enqueue([MockURLProtocol.json(["name": "models/gemini-test-002", "inputTokenLimit": 128_000,
            "outputTokenLimit": 8_192, "supportedGenerationMethods": ["generateContent"], "thinking": true])])
        let service = ProviderModelMetadataService(session: MockURLProtocol.session(), apiKey: "secret", windows: windows)
        #expect(try await service.refresh(provider: .google, model: "models/gemini-alias") == .fetched)
        #expect(windows.limits(for: .google, model: "models/gemini-alias")?.contextWindowTokens == 128_000)
        #expect(windows.limits(for: .google, model: "gemini-test-002")?.maxOutputTokens == 8_192)
        let reported = windows.reportedCapabilities(for: .google, model: "models/gemini-alias")
        #expect(reported?.canonicalModelID == "gemini-test-002" && reported?.reasoning == true)
        #expect(MockURLProtocol.lastRequest?.url?.path == "/v1beta/models/gemini-alias")
        #expect(MockURLProtocol.lastRequest?.url?.query == nil)
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-goog-api-key") == "secret")
    }

    @Test func groqDetailsProvideBothLimitsAndForceRefreshCanLowerThem() async throws {
        let suite = "ProviderHTTPTests.selectedGroq.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        windows.recordLimits(["model": AgentModelLimits(contextWindowTokens: 131_072, maxOutputTokens: 32_768)], provider: .groq)
        MockURLProtocol.enqueue([MockURLProtocol.json(["id": "model", "context_window": 64_000, "max_completion_tokens": 4_000])])
        let service = ProviderModelMetadataService(session: MockURLProtocol.session(), apiKey: "secret", windows: windows)
        #expect(try await service.refresh(provider: .groq, model: "model", force: true) == .fetched)
        #expect(windows.resolution(for: .groq, model: "model").contextWindowTokens == 64_000)
        #expect(windows.limits(for: .groq, model: "model")?.maxOutputTokens == 4_000)
        #expect(MockURLProtocol.lastRequest?.url?.path == "/openai/v1/models/model")
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func compatibleMetadataRefreshUsesTheListingInsteadOfInventingADetailRoute() async throws {
        let suite = "ProviderHTTPTests.compatibleMetadata.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        var provider = AIProvider.openAI
        provider.id = suite
        provider.baseURLString = "https://router.example/api/v1"
        MockURLProtocol.enqueue([MockURLProtocol.json(["data": [["id": "vendor/model", "context_length": 128_000,
            "top_provider": ["context_length": 64_000, "max_completion_tokens": 4_000]]]])])
        let service = ProviderModelMetadataService(session: MockURLProtocol.session(), apiKey: "secret", windows: windows)
        #expect(try await service.refresh(provider: provider, model: "vendor/model") == .fetched)
        #expect(windows.resolution(for: provider, model: "vendor/model").contextWindowTokens == 64_000)
        #expect(MockURLProtocol.lastRequest?.url?.path == "/api/v1/models")
    }

    @Test func failedDetailKeepsTheOldMetadataAndDefersRetry() async throws {
        let suite = "ProviderHTTPTests.failedMetadata.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        let old = AgentModelLimits(contextWindowTokens: 64_000, fetchedAt: Date().addingTimeInterval(-90_000))
        windows.recordLimits(["private-alias": old], provider: .anthropic)
        MockURLProtocol.enqueue([MockURLProtocol.json(["error": ["message": "Not found"]], status: 404)])
        let service = ProviderModelMetadataService(session: MockURLProtocol.session(), apiKey: "secret", windows: windows)
        #expect(try await service.refresh(provider: .anthropic, model: "private-alias") == .failed)
        #expect(windows.limits(for: .anthropic, model: "private-alias")?.contextWindowTokens == 64_000)
        #expect(windows.resolution(for: .anthropic, model: "private-alias").reason == .expiredMetadata)
        #expect(try await service.refresh(provider: .anthropic, model: "private-alias") == .deferred)
        #expect(MockURLProtocol.capturedRequests.count == 1)
    }

    @Test func unsupportedAndMissingCredentialsDoNotMakeRequests() async throws {
        MockURLProtocol.enqueue([])
        let suite = "ProviderHTTPTests.noMetadataKey.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ProviderModelMetadataService(session: MockURLProtocol.session(), apiKey: "", windows: ModelContextWindowStore(defaults: defaults))
        #expect(try await service.refresh(provider: .openAI, model: "gpt-6.1-terra") == .unsupported)
        #expect(try await service.refresh(provider: .anthropic, model: "claude-test") == .unavailable)
        #expect(MockURLProtocol.capturedRequests.isEmpty)
    }

    @Test func groqVendorIDsAreEncodedAndTraversalDoesNotSendARequest() async throws {
        let suite = "ProviderHTTPTests.groqPath.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        let service = ProviderModelMetadataService(session: MockURLProtocol.session(), apiKey: "secret", windows: windows)
        MockURLProtocol.enqueue([MockURLProtocol.json(["id": "vendor/model", "context_window": 64_000])])
        #expect(try await service.refresh(provider: .groq, model: "vendor/model") == .fetched)
        #expect(MockURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("models/vendor%2Fmodel") == true)
        MockURLProtocol.enqueue([])
        #expect(try await service.refresh(provider: .groq, model: "../outside", force: true) == .failed)
        #expect(MockURLProtocol.capturedRequests.isEmpty)
    }

    @Test func concurrentSelectedModelRefreshesMakeOneRequest() async throws {
        let suite = "ProviderHTTPTests.metadataDedup.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let windows = ModelContextWindowStore(defaults: defaults)
        MockURLProtocol.enqueue([MockURLProtocol.json(["id": "claude-model", "max_input_tokens": 64_000, "max_tokens": 4_000])])
        let service = ProviderModelMetadataService(session: MockURLProtocol.session(), apiKey: "secret",
                                                   windows: windows, coordinator: ProviderMetadataCoordinator())
        async let first = service.refresh(provider: .anthropic, model: suite)
        async let second = service.refresh(provider: .anthropic, model: suite)
        _ = try await (first, second)
        #expect(MockURLProtocol.capturedRequests.count == 1)
        #expect(windows.limits(for: .anthropic, model: suite)?.contextWindowTokens == 64_000)
    }
}
