//
//  ProviderModelsService.swift
//  Kurn
//
//  Lists usable summary models from each configured provider's own API.
//

import Foundation
import KurnCore

struct ProviderModelsService: Sendable {
    private let session: URLSession
    private let apiKey: String?
    private let contextWindows: ModelContextWindowStore
    private let anthropicVersion = "2023-06-01"

    /// - Parameters:
    ///   - session: URLSession used for the `/models` request.
    ///   - apiKey: Optional override for the provider's API key. When `nil`,
    ///     the key is read from the Keychain as usual. This is mainly for tests
    ///     so they can avoid racing on the process-wide Keychain.
    ///   - contextWindows: where context windows the listing reports are
    ///     remembered for `ContextBudget.resolve`.
    init(
        session: URLSession = .shared,
        apiKey: String? = nil,
        contextWindows: ModelContextWindowStore = .shared
    ) {
        self.session = session
        self.apiKey = apiKey
        self.contextWindows = contextWindows
    }

    func models(for provider: AIProvider) async throws -> [String] {
        // There is exactly one on-device model and no `/models` endpoint to ask.
        guard provider.kind != .appleOnDevice else { return [provider.defaultModel] }
        // ElevenLabs has no `/models` endpoint compatible with any of the
        // shapes below; its one supported model is the known fallback list.
        guard provider.kind != .elevenLabs else { return provider.fallbackModels }

        let apiKey = apiKey ?? KeychainManager.shared.value(for: provider.keychainAccount) ?? ""
        do {
            try LLMHTTP.requireAPIKey(apiKey, provider: provider)
        } catch {
            let code = (error as? AppError)?.logCode ?? "unexpected"
            AppLog.transcription.atError.error("ProviderModelsService: cannot load models for \(provider.displayName, privacy: .public) code=\(code, privacy: .public)")
            throw error
        }

        switch provider.kind {
        case .openAICompatible:
            let fetched: [String]
            do {
                fetched = try await fetchModels(provider: provider, as: OpenAIModelListResponse.self) { request in
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                } extract: { decoded in
                    let active = decoded.data.filter { $0.active != false }
                    recordWindows(active.map { ($0.id, $0.contextWindow) }, provider: provider)
                    return active.map(\.id)
                }
            } catch let AppError.apiError(status, _) where status == 403 && !provider.fallbackModels.isEmpty {
                // Some vendors' /models endpoints (e.g. Groq's) sometimes reject an
                // otherwise-valid key with 403. Fall back to a known model list so
                // the user can still pick a model, rather than surfacing a
                // confusing auth error for a key that actually works.
                AppLog.transcription.atInfo.info("ProviderModelsService: \(provider.displayName, privacy: .public) /models returned 403, falling back to known model list")
                return provider.fallbackModels
            } catch {
                let code = (error as? AppError)?.logCode ?? "unexpected"
                AppLog.transcription.atError.error("ProviderModelsService: failed to load models from \(provider.displayName, privacy: .public) code=\(code, privacy: .public)")
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
                let generative = decoded.models
                    .filter { $0.supportedGenerationMethods.contains("generateContent") }
                    .map { ($0.baseModelId ?? $0.name.replacingOccurrences(of: "models/", with: ""), $0.inputTokenLimit) }
                recordWindows(generative, provider: provider)
                return generative.map { $0.0 }
            }
            AppLog.transcription.atInfo.info("ProviderModelsService: loaded \(models.count, privacy: .public) model(s) from \(provider.displayName, privacy: .public)")
            return models
        case .elevenLabs:
            preconditionFailure("handled above")
        case .appleOnDevice:
            preconditionFailure("handled above")
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
        var request = URLRequest(url: try LLMHTTP.requireEndpoint(provider: provider, path: "models"))
        request.httpMethod = "GET"
        configure(&request)

        let (data, _) = try await LLMHTTP.sendValidated(request, session: session)
        return uniqueSorted(extract(try JSONDecoder().decode(type, from: data)))
    }

    /// Remember the context windows a listing reported, as (model id, window).
    private func recordWindows(_ models: [(String, Int?)], provider: AIProvider) {
        var windows: [String: Int] = [:]
        for (id, window) in models {
            if let window { windows[id] = window }
        }
        contextWindows.record(windows, providerID: provider.id)
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}

private struct OpenAIModelListResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let active: Bool?
        /// Groq names it `context_window`, OpenRouter `context_length`;
        /// OpenAI itself reports neither. Decoded leniently: a compatible
        /// server shaping it differently must not fail the whole listing.
        let contextWindow: Int?

        enum CodingKeys: String, CodingKey {
            case id, active
            case contextWindow = "context_window"
            case contextLength = "context_length"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            active = try? container.decodeIfPresent(Bool.self, forKey: .active)
            contextWindow = (try? container.decodeIfPresent(Int.self, forKey: .contextWindow))
                ?? (try? container.decodeIfPresent(Int.self, forKey: .contextLength))
        }
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
        let inputTokenLimit: Int?

        enum CodingKeys: String, CodingKey {
            case name, baseModelId, supportedGenerationMethods, inputTokenLimit
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            baseModelId = try container.decodeIfPresent(String.self, forKey: .baseModelId)
            supportedGenerationMethods = try container.decode([String].self, forKey: .supportedGenerationMethods)
            inputTokenLimit = try? container.decodeIfPresent(Int.self, forKey: .inputTokenLimit)
        }
    }

    let models: [Model]
}
