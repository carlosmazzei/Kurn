import AgentHarness
import Foundation
import KurnCore

/// Non-content provider metadata. V1 values lacked endpoint identity and timestamps,
/// so they are deliberately not promoted to evidence of an API response.
final class ModelContextWindowStore: @unchecked Sendable {
    static let shared = ModelContextWindowStore()
    private static let key = "modelContextCapabilities.v2"
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    func limits(for provider: AIProvider, model: String) -> AgentModelLimits? {
        lock.withLock { stored()[Self.entryKey(provider: provider, model: model)] }
    }

    func record(_ windows: [String: Int], provider: AIProvider) {
        recordLimits(windows.mapValues { AgentModelLimits(contextWindowTokens: $0, fetchedAt: now()) }, provider: provider)
    }

    func recordLimits(_ values: [String: AgentModelLimits], provider: AIProvider) {
        lock.withLock {
            var all = stored()
            for (model, limits) in values where !model.isEmpty {
                guard limits.contextWindowTokens != nil || limits.maxOutputTokens != nil else { continue }
                let entry = Self.entryKey(provider: provider, model: model)
                all[entry] = all[entry]?.merging(limits, now: now()) ?? limits
            }
            if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
        }
    }

    func resolution(for provider: AIProvider, model: String, metadataRefresh: AgentMetadataRefresh? = nil) -> AgentContextResolution {
        ModelContextWindows.resolve(model: model, reported: limits(for: provider, model: model), now: now(), metadataRefresh: metadataRefresh)
    }

    func agentContextWindow(for provider: AIProvider, model: String) -> Int {
        resolution(for: provider, model: model).contextWindowTokens
    }

    func hasFreshCompleteLimits(for provider: AIProvider, model: String) -> Bool {
        guard let value = limits(for: provider, model: model) else { return false }
        return value.contextWindowTokens != nil && value.maxOutputTokens != nil
            && ModelContextWindows.isFresh(value.contextTimestamp, now: now())
            && ModelContextWindows.isFresh(value.outputTimestamp, now: now())
    }

    func refreshIsDue(for provider: AIProvider, model: String) -> Bool {
        lock.withLock {
            let key = Self.entryKey(provider: provider, model: model)
            let attempts = defaults.dictionary(forKey: "modelContextRefreshAttempts.v1") as? [String: Date] ?? [:]
            guard let last = attempts[key] else { return true }
            let age = now().timeIntervalSince(last)
            return age < 0 || age >= 15 * 60
        }
    }

    func recordRefresh(for provider: AIProvider, model: String) {
        lock.withLock {
            var attempts = defaults.dictionary(forKey: "modelContextRefreshAttempts.v1") as? [String: Date] ?? [:]
            attempts = attempts.filter { now().timeIntervalSince($0.value) < 24 * 60 * 60 }
            attempts[Self.entryKey(provider: provider, model: model)] = now()
            defaults.set(attempts, forKey: "modelContextRefreshAttempts.v1")
        }
    }

    /// Capability facts the provider's model metadata reported (an alias's canonical ID, Gemini's
    /// `thinking`), kept apart from capacity under the same endpoint/model key. A report replaces only
    /// the facts it carries, each keeping its own age; even an empty one records that the provider was
    /// asked, so a fresh check is not repeated (`capabilitiesAreFresh`).
    func recordCapabilities(_ reported: AgentReportedCapabilities, provider: AIProvider, model: String) {
        guard !model.isEmpty else { return }
        lock.withLock {
            var all = storedCapabilities()
            let key = Self.entryKey(provider: provider, model: model)
            all[key] = all[key]?.merging(reported) ?? reported
            if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.capabilitiesKey) }
        }
    }

    /// Whether the provider was asked about this model's capabilities within the metadata lifetime.
    func capabilitiesAreFresh(for provider: AIProvider, model: String) -> Bool {
        guard let value = reportedCapabilities(for: provider, model: model) else { return false }
        return ModelContextWindows.isFresh(value.fetchedAt, now: now())
    }

    func reportedCapabilities(for provider: AIProvider, model: String) -> AgentReportedCapabilities? {
        lock.withLock { storedCapabilities()[Self.entryKey(provider: provider, model: model)] }
    }

    /// The run's capability snapshot (NH07): the catalog's facts, overridden by fresh provider reports.
    func capabilities(for provider: AIProvider, model: String, api: String, reasoningEffort: String?) -> AgentModelCapabilities {
        ModelCapabilityCatalog.resolve(api: api, model: model, reported: reportedCapabilities(for: provider, model: model),
                                       reasoningEffort: reasoningEffort, now: now())
    }

    private static let capabilitiesKey = "modelCapabilityFacts.v1"

    private func storedCapabilities() -> [String: AgentReportedCapabilities] {
        guard let data = defaults.data(forKey: Self.capabilitiesKey) else { return [:] }
        return (try? JSONDecoder().decode([String: AgentReportedCapabilities].self, from: data)) ?? [:]
    }

    private func stored() -> [String: AgentModelLimits] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: AgentModelLimits].self, from: data)) ?? [:]
    }

    private static func entryKey(provider: AIProvider, model: String) -> String {
        var origin = URLComponents(string: provider.baseURLString)
        origin?.user = nil
        origin?.password = nil
        origin?.query = nil
        origin?.fragment = nil
        let normalizedHost = origin?.host?.lowercased()
        let normalizedScheme = origin?.scheme?.lowercased()
        origin?.host = normalizedHost
        origin?.scheme = normalizedScheme
        let endpoint = origin?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        // Encoding the tuple avoids collisions between model IDs containing separators.
        let parts = [provider.id, provider.kind.rawValue, endpoint, model]
        return (try? JSONEncoder().encode(parts)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

extension ContextBudget {
    typealias Resolver = @Sendable (AIProvider, String) -> ContextBudget
    static let live: Resolver = { resolve(provider: $0, model: $1) }

    static func resolve(provider: AIProvider, model: String,
                        windows: ModelContextWindowStore = .shared) -> ContextBudget {
        guard provider.kind != .appleOnDevice else { return .onDevice }
        let resolution = windows.resolution(for: provider, model: model)
        guard resolution.source != .fixedFallback else { return .conservative }
        return .forContextWindow(resolution.contextWindowTokens, reservedOutputTokens: LLMHTTP.summaryMaxOutputTokens)
    }
}
