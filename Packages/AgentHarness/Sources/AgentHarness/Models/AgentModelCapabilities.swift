import Foundation

/// What a run's model can do, as known when the run started (NH07, C03). A versioned snapshot
/// recorded with the run (its context resolution and its `agent.run-start.v1` entry), so a reopened
/// conversation reads the facts the run was planned against instead of today's catalog.
///
/// Every capability is `unknown` unless the bundled catalog or the provider says otherwise: a name
/// the catalog does not recognize never inherits facts from a similar one. The snapshot holds no
/// credentials, endpoint or content.
public struct AgentModelCapabilities: Codable, Sendable, Equatable {
    /// The snapshot format. A later version may add fields; a reader ignores what it does not know.
    public static let currentVersion = 1

    public enum Support: String, Codable, Sendable { case supported, unsupported, unknown }

    /// How the vendor caches prompts for this model: by itself (`automatic`), only where a request
    /// marks what to cache (`explicit`), or not at all.
    public enum PromptCache: String, Codable, Sendable { case automatic, explicit, none, unknown }

    /// Where the facts came from: an exact catalog entry, a reviewed model-family rule, the provider's
    /// own model metadata (overriding the catalog for what it reported), or nowhere.
    public enum Source: String, Codable, Sendable { case catalog, family, api, unknown }

    public let version: Int
    /// The wire API the run's requests use (`anthropic`, `openAI`, `openAIResponses`, `gemini`).
    public let api: String
    /// The model the run asked for, as selected.
    public let modelID: String
    /// The model the provider resolved `modelID` to, when it reported one that differs (an alias).
    public let canonicalModelID: String?
    public let tools: Support
    public let reasoning: Support
    /// The reasoning effort the adapter sends with every request, or nil when it sends none.
    public let reasoningEffort: String?
    public let imageInput: Support
    public let promptCache: PromptCache
    public let source: Source
    public let catalogVersion: String?

    public init(api: String, modelID: String, canonicalModelID: String? = nil, tools: Support = .unknown,
                reasoning: Support = .unknown, reasoningEffort: String? = nil, imageInput: Support = .unknown,
                promptCache: PromptCache = .unknown, source: Source = .unknown, catalogVersion: String? = nil,
                version: Int = AgentModelCapabilities.currentVersion) {
        self.version = version
        self.api = api
        self.modelID = modelID
        self.canonicalModelID = canonicalModelID == modelID ? nil : canonicalModelID
        self.tools = tools
        self.reasoning = reasoning
        self.reasoningEffort = reasoningEffort
        self.imageInput = imageInput
        self.promptCache = promptCache
        self.source = source
        self.catalogVersion = catalogVersion
    }

    private enum CodingKeys: String, CodingKey {
        case version, api, modelID, canonicalModelID, tools, reasoning, reasoningEffort, imageInput, promptCache, source,
             catalogVersion
    }

    /// Tolerant on purpose: a value written by a later version (an unknown case) reads as `unknown`
    /// rather than making the run's record unreadable.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<Value: RawRepresentable>(_ key: CodingKeys, _ fallback: Value) -> Value where Value.RawValue == String {
            (try? values.decodeIfPresent(String.self, forKey: key)).flatMap { $0.flatMap(Value.init(rawValue:)) } ?? fallback
        }
        self.init(api: try values.decode(String.self, forKey: .api),
                  modelID: try values.decode(String.self, forKey: .modelID),
                  canonicalModelID: try? values.decodeIfPresent(String.self, forKey: .canonicalModelID),
                  tools: value(.tools, Support.unknown), reasoning: value(.reasoning, Support.unknown),
                  reasoningEffort: try? values.decodeIfPresent(String.self, forKey: .reasoningEffort),
                  imageInput: value(.imageInput, Support.unknown), promptCache: value(.promptCache, PromptCache.unknown),
                  source: value(.source, Source.unknown),
                  catalogVersion: try? values.decodeIfPresent(String.self, forKey: .catalogVersion),
                  version: (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? 1)
    }
}

/// Capability facts the provider's own model metadata reported (today Gemini's `thinking`), and the
/// canonical ID it resolved an alias to. Each is optional and independent; none is inferred.
public struct AgentReportedCapabilities: Codable, Sendable, Equatable {
    public let canonicalModelID: String?
    public let reasoning: Bool?
    public let fetchedAt: Date

    public init(canonicalModelID: String? = nil, reasoning: Bool? = nil, fetchedAt: Date = Date()) {
        self.canonicalModelID = canonicalModelID
        self.reasoning = reasoning
        self.fetchedAt = fetchedAt
    }

    public var isEmpty: Bool { canonicalModelID == nil && reasoning == nil }
}

/// Bundled capability facts, reviewed against the vendors' model documentation on 2026-11-14.
/// Exact entries come first; a family rule applies only to a prefix whose every current model shares
/// the fact. Anything else stays `unknown`.
public enum ModelCapabilityCatalog {
    public static let version = "2026-11-14"

    struct Facts: Equatable {
        let tools: AgentModelCapabilities.Support
        let reasoning: AgentModelCapabilities.Support
        let imageInput: AgentModelCapabilities.Support
    }

    /// The snapshot for `model` on `api`. `reported` overrides what the catalog says about the same
    /// fact, but only while its metadata is fresh; `reasoningEffort` is what the adapter will send.
    public static func resolve(api: String, model: String, reported: AgentReportedCapabilities? = nil,
                               reasoningEffort: String? = nil, now: Date = Date()) -> AgentModelCapabilities {
        let fresh = reported.flatMap { ModelContextWindows.isFresh($0.fetchedAt, now: now) ? $0 : nil }
        let canonical = fresh?.canonicalModelID
        // A qualified alias mapping lets the canonical model's facts apply to the alias.
        let match = facts(for: canonical ?? model) ?? (canonical == nil ? nil : facts(for: model))
        var reasoning = match?.facts.reasoning ?? .unknown
        var source = match?.source ?? .unknown
        if let reported = fresh?.reasoning {
            reasoning = reported ? .supported : .unsupported
            source = .api
        }
        return AgentModelCapabilities(
            api: api, modelID: model, canonicalModelID: canonical,
            tools: match?.facts.tools ?? .unknown, reasoning: reasoning, reasoningEffort: reasoningEffort,
            imageInput: match?.facts.imageInput ?? .unknown,
            promptCache: match == nil ? .unknown : promptCache(api: api, model: canonical ?? model),
            source: source, catalogVersion: match == nil ? nil : version)
    }

    static func facts(for model: String) -> (facts: Facts, source: AgentModelCapabilities.Source)? {
        let name = model.split(separator: "/").last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !name.isEmpty else { return nil }
        if let exact = exactEntry(name) { return (exact, .catalog) }
        guard let family = families.filter({ name.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count })
        else { return nil }
        return (family.facts, .family)
    }

    private static func exactEntry(_ name: String) -> Facts? {
        if let entry = entries[name] { return entry }
        // Only a documented date-shaped snapshot suffix inherits an exact model's facts.
        guard name.count > 11 else { return nil }
        let suffix = String(name.suffix(11))
        guard suffix.range(of: #"^-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return entries[String(name.dropLast(11))]
    }

    /// The vendor's caching mechanism, which belongs to the API serving the model: a compatible
    /// endpoint (OpenRouter, Groq, a custom server) may cache or not, so it stays unknown.
    private static func promptCache(api: String, model: String) -> AgentModelCapabilities.PromptCache {
        switch api {
        case "anthropic": return .explicit
        case "openAIResponses": return .automatic
        case "gemini":
            let name = model.split(separator: "/").last.map { $0.lowercased() } ?? ""
            return name.hasPrefix("gemini-1") ? .unknown : .automatic
        default: return .unknown
        }
    }

    private static let entries: [String: Facts] = {
        var result: [String: Facts] = [:]
        let reasoningModel = Facts(tools: .supported, reasoning: .supported, imageInput: .supported)
        for model in ["gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.4", "gpt-5.4-pro",
                      "gpt-5.4-mini", "gpt-5.2", "gpt-5.1", "gpt-5", "gpt-5-mini", "gpt-5-nano",
                      "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-3.6-flash"] {
            result[model] = reasoningModel
        }
        for model in ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini"] {
            result[model] = Facts(tools: .supported, reasoning: .unsupported, imageInput: .supported)
        }
        for model in ["o3", "o4-mini"] { result[model] = reasoningModel }
        result["llama-3.3-70b-versatile"] = Facts(tools: .supported, reasoning: .unsupported, imageInput: .unsupported)
        // The first small reasoning model shipped without function calling or image input.
        result["o1-mini"] = Facts(tools: .unsupported, reasoning: .supported, imageInput: .unsupported)
        return result
    }()

    /// Claude 3 and later call tools and read images; extended thinking depends on the model. Other
    /// families have members without tools (search, audio, image-generation variants), so they are
    /// listed exactly instead.
    private static let families: [(prefix: String, facts: Facts)] = ["claude-3", "claude-opus-", "claude-sonnet-", "claude-haiku-"]
        .map { ($0, Facts(tools: .supported, reasoning: .unknown, imageInput: .supported)) }
}
