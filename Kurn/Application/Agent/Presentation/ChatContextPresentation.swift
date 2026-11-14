import AgentHarness
import Foundation

public enum ChatContextPresentation {
    public static func sourceKey(_ resolution: AgentContextResolution) -> String {
        switch resolution.source {
        case .api: resolution.isCached ? "chat.context.api_cached" : "chat.context.api"
        case .fixedTable: "chat.context.table"
        case .fixedFallback: "chat.context.fallback"
        }
    }

    /// The run's model capability snapshot as lines (NH07): the resolved alias first, then tools,
    /// reasoning (and the effort sent), image input and prompt caching.
    public static func capabilityLines(_ capabilities: AgentModelCapabilities, localize: (String) -> String) -> [String] {
        func line(_ key: String, _ value: String) -> String { String(format: localize("chat.capability.\(key)"), value) }
        func support(_ value: AgentModelCapabilities.Support) -> String { localize("chat.capability.support.\(value.rawValue)") }
        var lines: [String] = []
        if let canonical = capabilities.canonicalModelID { lines.append(line("canonical", canonical)) }
        lines.append(line("tools", support(capabilities.tools)))
        lines.append(line("reasoning", support(capabilities.reasoning)))
        if let effort = capabilities.reasoningEffort { lines.append(line("effort", effort)) }
        lines.append(line("images", support(capabilities.imageInput)))
        lines.append(line("cache", localize("chat.capability.cache.\(capabilities.promptCache.rawValue)")))
        return lines
    }

    public static func diagnosticDetails(_ diagnostic: AgentDiagnostic, localize: (String) -> String) -> String {
        var lines = diagnostic.metrics.sorted { $0.key.rawValue < $1.key.rawValue }.map {
            "\(localize("chat.metric.\($0.key.rawValue)")): \($0.value)"
        }
        if let reason = diagnostic.stopReason { lines.insert(localize("chat.step.stop.\(reason.rawValue)"), at: 0) }
        return lines.joined(separator: "\n")
    }
}
