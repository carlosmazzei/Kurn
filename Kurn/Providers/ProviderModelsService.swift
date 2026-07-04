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
        do {
            try LLMHTTP.requireAPIKey(apiKey, provider: provider)
        } catch {
            AppLog.transcription.atError.error("ProviderModelsService: cannot load models for \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        switch provider.kind {
        case .openAICompatible:
            let fetched: [String]
            do {
                fetched = try await fetchModels(provider: provider, as: OpenAIModelListResponse.self) { request in
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                } extract: { decoded in
                    decoded.data.filter { $0.active != false }.map(\.id)
                }
            } catch let AppError.apiError(status, _) where status == 403 && !provider.fallbackModels.isEmpty {
                // Some vendors' /models endpoints (e.g. Groq's) sometimes reject an
                // otherwise-valid key with 403. Fall back to a known model list so
                // the user can still pick a model, rather than surfacing a
                // confusing auth error for a key that actually works.
                AppLog.transcription.atInfo.info("ProviderModelsService: \(provider.displayName, privacy: .public) /models returned 403, falling back to known model list")
                return provider.fallbackModels
            } catch {
                AppLog.transcription.atError.error("ProviderModelsService: failed to load models from \(provider.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw error
            }
            if fetched.isEmpty, !provider.fallbackModels.isEmpty {
                AppLog.transcription.atInfo.info("ProviderModelsService: \(provider.displayName, privacy: .public) returned no models, falling back to known model list")
                return provider.fallbackModels
            }
            AppLog.transcription.atInfo.info("ProviderModelsService: loaded \(fetched.count, privacy: .public) model(s) from \(provider.displayName, privacy: .public)")
            return fetched
        case .anthropic:
            let models = try await fetchModels(provider: provider, as: AnthropicModelListResponse.self) { request in
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            } extract: { decoded in
                decoded.data.map(\.id)
            }
            AppLog.transcription.atInfo.info("ProviderModelsService: loaded \(models.count, privacy: .public) model(s) from \(provider.displayName, privacy: .public)")
            return models
        case .googleGemini:
            let models = try await fetchModels(provider: provider, as: GoogleModelListResponse.self) { request in
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            } extract: { decoded in
                decoded.models
                    .filter { $0.supportedGenerationMethods.contains("generateContent") }
                    .map { $0.baseModelId ?? $0.name.replacingOccurrences(of: "models/", with: "") }
            }
            AppLog.transcription.atInfo.info("ProviderModelsService: loaded \(models.count, privacy: .public) model(s) from \(provider.displayName, privacy: .public)")
            return models
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
