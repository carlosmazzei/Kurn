//
//  ChatReasoningPreference.swift
//  Kurn
//
//  The chat's reasoning level: what the person picked (`AppSettings.chatReasoningLevel`) and what
//  a request actually carries for a given provider and model. The harness maps the level per
//  vendor (`AgentReasoningLevel`); this decides whether to send it at all.
//

import AgentHarness
import Foundation
import KurnCore

enum ChatReasoningPreference {
    /// The level the person picked; nil (or anything unreadable) is the vendor's default.
    static func stored(_ defaults: UserDefaults = .standard) -> AgentReasoningLevel? {
        defaults.string(forKey: AppSettings.Keys.chatReasoningLevel).flatMap(AgentReasoningLevel.init(rawValue:))
    }

    /// The API shape the provider's agent model speaks, as `AgentModelDescriptor.api` names it.
    static func api(for provider: AIProvider) -> String {
        switch provider.kind {
        case .anthropic: "anthropic"
        case .googleGemini: "gemini"
        case .openAICompatible:
            OpenAIResponsesText.isOfficial(providerID: provider.id, baseURL: provider.baseURLString) ? "openAIResponses" : "openAI"
        case .elevenLabs, .appleOnDevice: "none"
        }
    }

    /// Whether a level can be offered: never for a model known not to reason, and on a compatible
    /// endpoint only for a model known to reason, since an unknown server may reject the field.
    static func isOffered(provider: AIProvider, capabilities: AgentModelCapabilities) -> Bool {
        guard provider.kind.supportsAgentChat else { return false }
        switch capabilities.reasoning {
        case .unsupported: return false
        case .supported: return true
        case .unknown: return api(for: provider) != "openAI"
        }
    }

    /// The catalog's facts, overridden by what the provider recently reported (Gemini's `thinking`,
    /// for one) — the same snapshot the run records.
    static func capabilities(provider: AIProvider, model: String,
                             store: ModelContextWindowStore = .shared) -> AgentModelCapabilities {
        store.capabilities(for: provider, model: model, api: api(for: provider), reasoningEffort: nil)
    }

    /// What a request carries: the chosen level when the model can take it, otherwise nil.
    static func level(_ chosen: AgentReasoningLevel?, provider: AIProvider, capabilities: AgentModelCapabilities) -> AgentReasoningLevel? {
        guard let chosen, isOffered(provider: provider, capabilities: capabilities) else { return nil }
        return chosen
    }

    /// The level for the stored choice and this provider and model. The model factory asks for it
    /// per request, so it sees metadata the run refreshed before its first request.
    static func level(for provider: AIProvider, model: String, defaults: UserDefaults = .standard,
                      store: ModelContextWindowStore = .shared) -> AgentReasoningLevel? {
        level(stored(defaults), provider: provider, capabilities: capabilities(provider: provider, model: model, store: store))
    }
}
