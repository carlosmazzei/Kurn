import AgentHarness
import Foundation
import KurnCore

/// Selected-model metadata uses the existing origin-locked transport, never the LLM endpoint.
struct ProviderModelMetadataService: Sendable {
    var session: URLSession = .shared
    var apiKey: String?
    var windows: ModelContextWindowStore = .shared
    var coordinator: ProviderMetadataCoordinator = .shared

    func refresh(provider: AIProvider, model: String, force: Bool = false) async throws -> AgentMetadataRefresh {
        try Task.checkCancellation()
        let host = URLComponents(string: provider.baseURLString)?.host?.lowercased()
        guard !model.isEmpty, ![.appleOnDevice, .elevenLabs].contains(provider.kind) else { return .unsupported }
        if !force && windows.hasFreshCompleteLimits(for: provider, model: model) { return .cacheFresh }
        guard !(provider.kind == .openAICompatible && host == "api.openai.com") else { return .unsupported }
        let key = apiKey ?? KeychainManager.shared.value(for: provider.keychainAccount) ?? ""
        guard !key.isEmpty else { return .unavailable }
        let identity = ProviderMetadataCoordinator.Identity(store: ObjectIdentifier(windows), provider: provider.id, kind: provider.kind,
            endpoint: provider.baseURLString, model: model, credential: key)
        let status = await coordinator.run(identity: identity) {
            if !force && !windows.refreshIsDue(for: provider, model: model) { return .deferred }
            AppLog.generation.atNotice.notice("model_metadata_refresh phase=started")
            let result = await fetch(provider: provider, model: model, key: key, host: host)
            windows.recordRefresh(for: provider, model: model)
            AppLog.generation.atNotice.notice("model_metadata_refresh outcome=\(result.rawValue, privacy: .public)")
            return result
        }
        try Task.checkCancellation()
        return status
    }

    private func fetch(provider: AIProvider, model: String, key: String, host: String?) async -> AgentMetadataRefresh {
        do {
            let value: AgentModelLimits
            switch provider.kind {
            case .anthropic:
                let request = try detailRequest(provider: provider, model: model, key: key)
                let (data, _) = try await LLMHTTP.sendValidated(request, session: session)
                let result = try JSONDecoder().decode(AnthropicModelListResponse.Model.self, from: data)
                guard !result.id.isEmpty else { return .notReported }
                value = result.limits
                windows.recordLimits([result.id: value], provider: provider)
                // An alias the provider resolved qualifies the run's capability snapshot (C04).
                windows.recordCapabilities(AgentReportedCapabilities(canonicalModelID: result.id == model ? nil : result.id),
                                           provider: provider, model: model)
            case .googleGemini:
                let request = try detailRequest(provider: provider, model: model, key: key)
                let (data, _) = try await LLMHTTP.sendValidated(request, session: session)
                let result = try JSONDecoder().decode(GoogleModelListResponse.Model.self, from: data)
                guard !result.requestID.isEmpty, result.supportedGenerationMethods.contains("generateContent") else { return .notReported }
                value = result.limits
                windows.recordLimits([result.requestID: value], provider: provider)
                let requested = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
                windows.recordCapabilities(AgentReportedCapabilities(
                    canonicalModelID: result.requestID == requested ? nil : result.requestID, reasoning: result.thinking),
                    provider: provider, model: model)
            case .openAICompatible where host == "api.groq.com":
                let request = try detailRequest(provider: provider, model: model, key: key)
                let (data, _) = try await LLMHTTP.sendValidated(request, session: session)
                let result = try JSONDecoder().decode(OpenAIModelListResponse.Model.self, from: data)
                guard !result.id.isEmpty, result.active != false else { return .notReported }
                value = result.limits
            default:
                // OpenRouter/custom compatible APIs have no universal model-detail route.
                let previous = windows.limits(for: provider, model: model)?.contextTimestamp
                _ = try await ProviderModelsService(session: session, apiKey: key, contextWindows: windows,
                                                    requestTimeout: 8).models(for: provider)
                guard let current = windows.limits(for: provider, model: model), current.contextWindowTokens != nil,
                      current.contextTimestamp != previous, ModelContextWindows.isFresh(current.contextTimestamp) else { return .notReported }
                return .fetched
            }
            windows.recordLimits([model: value], provider: provider)
            return value.contextWindowTokens == nil ? .notReported : .fetched
        } catch {
            AppLog.generation.atNotice.notice("model_metadata_refresh outcome=failed")
            return .failed
        }
    }

    private func detailRequest(provider: AIProvider, model: String, key: String) throws -> URLRequest {
        let id = provider.kind == .googleGemini && model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        guard !id.isEmpty, !id.contains("\\"),
              provider.kind == .openAICompatible || !id.contains("/") else { throw AppError.invalidProviderURL }
        // Validate traversal through the shared URL policy, then encode Groq's vendor/model
        // identifiers as one component instead of introducing another route segment.
        _ = try LLMHTTP.requireEndpoint(provider: provider, path: "models/" + id)
        let root = try LLMHTTP.requireEndpoint(provider: provider, path: "models")
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let component = id.addingPercentEncoding(withAllowedCharacters: allowed),
              var url = URLComponents(url: root, resolvingAgainstBaseURL: false) else { throw AppError.invalidProviderURL }
        url.percentEncodedPath += "/" + component
        guard let endpoint = url.url else { throw AppError.invalidProviderURL }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        switch provider.kind {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .googleGemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

actor ProviderMetadataCoordinator {
    static let shared = ProviderMetadataCoordinator()
    struct Identity: Hashable, Sendable {
        let store: ObjectIdentifier
        let provider: String
        let kind: AIProviderKind
        let endpoint: String
        let model: String
        // In-memory identity only. Never persisted, logged or exported.
        let credential: String
    }
    private var tasks: [Identity: Task<AgentMetadataRefresh, Never>] = [:]

    func run(identity: Identity, operation: @escaping @Sendable () async -> AgentMetadataRefresh) async -> AgentMetadataRefresh {
        if let task = tasks[identity] { return await task.value }
        guard tasks.count < 4 else { return .deferred }
        let task = Task { await operation() }
        tasks[identity] = task
        let result = await task.value
        tasks[identity] = nil
        return result
    }
}
