//
//  ProviderModelsService.swift
//  Kurn
//
//  Lists usable summary models from each configured provider's own API.
//

import Foundation

struct ProviderModelsService: Sendable {
    private let session: URLSession
    private let anthropicVersion = "2023-06-01"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func models(for provider: AIProvider) async throws -> [String] {
        let apiKey = KeychainManager.shared.get(provider.keychainAccount) ?? ""
        try LLMHTTP.requireAPIKey(apiKey, provider: provider)

        switch provider.kind {
        case .openAICompatible:
            return try await fetchModels(provider: provider, as: OpenAIModelListResponse.self) { request in
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            } extract: { decoded in
                decoded.data.filter { $0.active != false }.map(\.id)
            }
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
