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
        guard !apiKey.isEmpty else { throw AppError.noAPIKey(provider: provider.displayName) }

        switch provider.kind {
        case .openAICompatible:
            return try await openAICompatibleModels(provider: provider, apiKey: apiKey)
        case .anthropic:
            return try await anthropicModels(provider: provider, apiKey: apiKey)
        case .googleGemini:
            return try await googleModels(provider: provider, apiKey: apiKey)
        }
    }

    private func openAICompatibleModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        guard let url = LLMHTTP.endpoint(baseURLString: provider.baseURLString, path: "models") else {
            throw AppError.apiError(statusCode: 0, message: "Invalid provider URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        let decoded = try JSONDecoder().decode(OpenAIModelListResponse.self, from: data)
        return uniqueSorted(decoded.data.filter { $0.active != false }.map(\.id))
    }

    private func anthropicModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        guard let url = LLMHTTP.endpoint(baseURLString: provider.baseURLString, path: "models") else {
            throw AppError.apiError(statusCode: 0, message: "Invalid provider URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        let decoded = try JSONDecoder().decode(AnthropicModelListResponse.self, from: data)
        return uniqueSorted(decoded.data.map(\.id))
    }

    private func googleModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        guard let url = LLMHTTP.endpoint(baseURLString: provider.baseURLString, path: "models"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AppError.apiError(statusCode: 0, message: "Invalid provider URL")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)

        let decoded = try JSONDecoder().decode(GoogleModelListResponse.self, from: data)
        let models = decoded.models
            .filter { $0.supportedGenerationMethods.contains("generateContent") }
            .map { $0.baseModelId ?? $0.name.replacingOccurrences(of: "models/", with: "") }
        return uniqueSorted(models)
    }

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
