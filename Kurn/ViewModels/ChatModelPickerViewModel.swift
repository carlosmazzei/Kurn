//
//  ChatModelPickerViewModel.swift
//  Kurn
//
//  The chat's model and reasoning choice for the configured provider: the provider's listed
//  models (the chosen one always shown, the known list when listing fails) and whether the
//  chosen model can take a reasoning level (`ChatReasoningPreference`). The choices themselves
//  live in `AppSettings`; the chat shares its model with summaries.
//

import AgentHarness
import Foundation
import Observation

@MainActor
@Observable
final class ChatModelPickerViewModel {
    typealias Loader = @Sendable (AIProvider) async throws -> [String]

    let provider: AIProvider
    private(set) var models: [String]
    private(set) var isLoading = false
    private(set) var loadFailed = false
    @ObservationIgnored private let load: Loader

    init(provider: AIProvider, current: String, load: @escaping Loader = { try await ProviderModelsService().models(for: $0) }) {
        self.provider = provider
        self.load = load
        models = Self.options(loaded: [], current: current, fallback: provider.fallbackModels)
    }

    func refresh(current: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            models = Self.options(loaded: try await load(provider), current: current, fallback: provider.fallbackModels)
            loadFailed = false
        } catch {
            models = Self.options(loaded: [], current: current, fallback: provider.fallbackModels)
            loadFailed = true
        }
    }

    /// The listed models, or the known list when nothing was listed, with the chosen model first
    /// when the list lacks it; no duplicates or blanks.
    static func options(loaded: [String], current: String, fallback: [String]) -> [String] {
        var seen = Set<String>()
        let source = loaded.isEmpty ? fallback : loaded
        let ordered = (source.contains(current) ? source : [current] + source)
        return ordered.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func offersReasoning(model: String) -> Bool {
        ChatReasoningPreference.isOffered(provider: provider,
                                          capabilities: ChatReasoningPreference.capabilities(provider: provider, model: model))
    }

    /// The composer chip: the model, and the level when one is chosen and the model takes it.
    static func chipText(model: String, level: AgentReasoningLevel?, offered: Bool, localize: (String) -> String) -> String {
        guard let level, offered else { return model }
        return model + " · " + localize("chat.reasoning.\(level.rawValue)")
    }
}
