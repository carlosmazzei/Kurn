//
//  ProviderModelsService.swift
//  Kurn
//
//  Lists usable summary models from each configured provider's own API.
//

import Foundation

struct ProviderModelsService: Sendable {
    private let session: URLSession
    private let apiKey: String?
    private let anthropicVersion = "2023-06-01"

    /// - Parameters:
    ///   - session: URLSession used for the `/models` request.
    ///   - apiKey: Optional override for the provider's API key. When `nil`,
    ///     the key is read from the Keychain as usual. This is mainly for tests
    ///     so they can avoid racing on the process-wide Keychain.
    init(session: URLSession = .shared, apiKey: String? = nil) {
        self.session = session
        self.apiKey = apiKey
    }

    func models(for provider: AIProvider) async throws -> [String] {
        let apiKey = apiKey ?? KeychainManager.shared.get(provider.keychainAccount) ?? ""
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        switch provider.kind {
        case .openAICompatible:
            let fetched: [String]
            do {
                fetched = try await fetchModels(provider: provider, as: OpenAIModelListResponse.self) { request in
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                } extract: { decoded in
                    decoded.data.filter { $0.active != false }.map(\.id)
                }
            } catch {
                // Groq's /models endpoint sometimes rejects otherwise-valid keys with 403.
                // Fall back to a known model list so the user can still pick a model.
                if provider.id == AIProvider.groq.id {
                    return Self.groqFallbackModels
                }
                throw error
            }
            if provider.id == AIProvider.groq.id, fetched.isEmpty {
                return Self.groqFallbackModels
            }
            return fetched
        case .anthropic:
            return try await fetchModels(provider: provider, as: AnthropicModelListResponse.self) { request in
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            } extract: { decoded in
                decoded.data.map(\.id)
            }
        case .googleGemini:
            return try await fetchModels(provider: provider, as: GoogleModelListResponse.self) { request in
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            } extract: { decoded in
                decoded.models
                    .filter { $0.supportedGenerationMethods.contains("generateContent") }
                    .map { $0.baseModelId ?? $0.name.replacingOccurrences(of: "models/", with: "") }
            }
        }
    }

    /// Shared GET-and-decode flow for a provider's `/models` listing: build the
    /// endpoint, apply provider-specific auth via `configure`, send, decode, and
    /// reduce to a unique sorted list via `extract`.
    private func fetchModels<T: Decodable>(
        provider: AIProvider,
        as type: T.Type,
        configure: (inout URLRequest) -> Void,
        extract: (T) -> [String]
    ) async throws -> [String] {
        guard let url = LLMHTTP.endpoint(baseURLString: provider.baseURLString, path: "models") else {
            throw Self.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        configure(&request)

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)
        return uniqueSorted(extract(try JSONDecoder().decode(type, from: data)))
    }

    /// Models known to be available on GroqCloud. Used when the provider's
    /// `/models` endpoint is not reachable for the configured key (e.g. 403).
    private static let groqFallbackModels: [String] = [
        "llama-3.3-70b-versatile",
        "llama-3.3-70b-specdec",
        "llama-3.1-8b-instant",
        "meta-llama/llama-4-scout-17b-16e-instruct",
        "meta-llama/llama-4-maverick-17b-128e-instruct",
        "gemma2-9b-it",
        "deepseek-r1-distill-llama-70b",
        "qwen/qwen3-32b",
        "whisper-large-v3",
        "whisper-large-v3-turbo"
    ].sorted()

    private static let invalidURL = AppError.apiError(statusCode: 0, message: "Invalid provider URL")

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}

private struct OpenAIModelListResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let active: Bool?
    }

    let data: [Model]
}

private struct AnthropicModelListResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct GoogleModelListResponse: Decodable {
    struct Model: Decodable {
        let name: String
        let baseModelId: String?
        let supportedGenerationMethods: [String]
    }

    let models: [Model]
}
