import Foundation

/// Host-supplied workload facts; no document bodies, domain types or task-language heuristics.
public struct AgentWorkload: Sendable, Equatable {
    public let sourceCount: Int
    public let readableParts: Int
    public let estimatedReadPages: Int

    public init(sourceCount: Int, readableParts: Int, estimatedReadPages: Int) {
        self.sourceCount = max(0, min(1_000_000, sourceCount))
        self.readableParts = max(0, min(10_000_000, readableParts))
        self.estimatedReadPages = max(0, min(10_000_000, estimatedReadPages))
    }

    public var metrics: [AgentDiagnostic.Metric: Int] {
        [.selectedSources: sourceCount, .selectedParts: readableParts, .estimatedReadPages: estimatedReadPages]
    }
}

public struct AgentContinuationBudget: Sendable, Equatable {
    public let maxTurns: Int
    public let maxToolCalls: Int
    public let turnStep: Int
    public let toolStep: Int
    public let minimumProgress: Int

    public init(maxTurns: Int = 64, maxToolCalls: Int = 256, turnStep: Int = 8,
                toolStep: Int = 32, minimumProgress: Int = 2) {
        self.maxTurns = max(0, min(64, maxTurns))
        self.maxToolCalls = max(0, min(256, maxToolCalls))
        self.turnStep = max(1, min(64, turnStep))
        self.toolStep = max(1, min(256, toolStep))
        self.minimumProgress = max(1, minimumProgress)
    }
}

public enum AgentBudgetPlanner {
    public static func limits(for workload: AgentWorkload, maxCostUSD: Double? = nil) -> AgentLimits {
        let calls = min(192, max(20, 12 + workload.readableParts + workload.estimatedReadPages * 2))
        let turns = min(48, max(10, 8 + workload.sourceCount / 2 + workload.estimatedReadPages / 4))
        return AgentLimits(maxTurns: turns, maxToolCalls: calls, maxCostUSD: maxCostUSD, wrapUpOnLimit: true,
                           continuation: AgentContinuationBudget(), workload: workload)
    }
}

extension AgentLimits {
    var diagnosticMetrics: [AgentDiagnostic.Metric: Int] {
        var result = workload?.metrics ?? [:]
        result[.maxTurns] = maxTurns
        result[.maxToolCalls] = maxToolCalls
        result[.hardMaxTurns] = continuation?.maxTurns ?? maxTurns
        result[.hardMaxToolCalls] = continuation?.maxToolCalls ?? maxToolCalls
        result[.minimumProgress] = continuation?.minimumProgress ?? 0
        return result
    }
}
