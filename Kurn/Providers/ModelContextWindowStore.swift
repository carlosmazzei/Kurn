//
//  ModelContextWindowStore.swift
//  Kurn
//
//  Context windows a provider's own `/models` listing reported (Gemini's
//  `inputTokenLimit`, Groq's `context_window`, OpenRouter's
//  `context_length`), remembered so a later summary can plan against the
//  real window instead of `ModelContextWindows`' table or the conservative
//  default. Model ids and token counts only — nothing meeting-derived — so
//  `UserDefaults` is an appropriate home.
//

import Foundation
import KurnCore

final class ModelContextWindowStore: @unchecked Sendable {
    static let shared = ModelContextWindowStore()

    private static let key = "modelContextWindows.v1"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The window last reported for `model` on `providerID`, if any.
    func window(providerID: String, model: String) -> Int? {
        lock.withLock { stored()[Self.entryKey(providerID: providerID, model: model)] }
    }

    /// Merge freshly reported windows for one provider. Non-positive values
    /// are ignored rather than stored, so a vendor reporting `0` for
    /// "unknown" can never shrink a budget to nothing.
    func record(_ windows: [String: Int], providerID: String) {
        let valid = windows.filter { !$0.key.isEmpty && $0.value > 0 }
        guard !valid.isEmpty else { return }
        lock.withLock {
            var all = stored()
            for (model, tokens) in valid {
                all[Self.entryKey(providerID: providerID, model: model)] = tokens
            }
            defaults.set(all, forKey: Self.key)
        }
    }

    private func stored() -> [String: Int] {
        defaults.dictionary(forKey: Self.key) as? [String: Int] ?? [:]
    }

    private static func entryKey(providerID: String, model: String) -> String {
        "\(providerID)|\(model.lowercased())"
    }
}

extension ContextBudget {
    /// Decides the budget for a (provider, model) pair. Services take one at
    /// construction so tests can force either path with a tiny transcript.
    typealias Resolver = @Sendable (AIProvider, String) -> ContextBudget

    static let live: Resolver = { resolve(provider: $0, model: $1) }

    /// The single-request budget for `model` on `provider`: the on-device
    /// budget for Apple's model; otherwise the window the provider reported,
    /// else the known window for the model's family, else
    /// `ContextBudget.conservative`.
    static func resolve(
        provider: AIProvider,
        model: String,
        windows: ModelContextWindowStore = .shared
    ) -> ContextBudget {
        guard provider.kind != .appleOnDevice else { return .onDevice }
        let window = windows.window(providerID: provider.id, model: model)
            ?? ModelContextWindows.knownWindow(forModel: model)
        guard let window else { return .conservative }
        return .forContextWindow(window, reservedOutputTokens: LLMHTTP.summaryMaxOutputTokens)
    }
}
