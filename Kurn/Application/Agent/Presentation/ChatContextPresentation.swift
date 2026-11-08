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

    public static func diagnosticDetails(_ diagnostic: AgentDiagnostic, localize: (String) -> String) -> String {
        var lines = diagnostic.metrics.sorted { $0.key.rawValue < $1.key.rawValue }.map {
            "\(localize("chat.metric.\($0.key.rawValue)")): \($0.value)"
        }
        if let reason = diagnostic.stopReason { lines.insert(localize("chat.step.stop.\(reason.rawValue)"), at: 0) }
        return lines.joined(separator: "\n")
    }
}
