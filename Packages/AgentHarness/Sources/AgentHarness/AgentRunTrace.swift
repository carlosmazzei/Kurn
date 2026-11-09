import Foundation

public struct AgentRunStep: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case turn, tool, compaction, stop, context, diagnostic }
    public enum Status: String, Codable, Sendable { case running, finished, failed }

    public let id: UUID
    public let kind: Kind
    public var status: Status
    public var turnIndex: Int?
    public var callID: String?
    public var toolName: String?
    public var arguments: JSONValue?
    public var outputSummary: String?
    public var beforeTokens: Int?
    public var afterTokens: Int?
    public var stopReason: AgentRunStopReason?
    public var contextResolution: AgentContextResolution?
    public var diagnostic: AgentDiagnostic?
    public var argumentsSummary: String? { arguments.flatMap { try? $0.encodedString() } }

    public init(kind: Kind, status: Status = .running) {
        id = UUID()
        self.kind = kind
        self.status = status
    }
}

public struct AgentRunTrace: Sendable, Equatable {
    public private(set) var steps: [AgentRunStep] = []
    public private(set) var usage = AgentUsage()
    public private(set) var hasUsage = false

    public init() {}

    public mutating func apply(_ event: AgentEvent) {
        switch event {
        case .runStarted:
            steps = []
            usage = AgentUsage()
            hasUsage = false
        case .turnStarted(let index):
            finishTurn()
            var step = AgentRunStep(kind: .turn)
            step.turnIndex = index
            steps.append(step)
        case .contextResolved(let resolution):
            var step = AgentRunStep(kind: .context, status: .finished)
            step.contextResolution = resolution
            steps.append(step)
        case .diagnostic(let diagnostic):
            var step = AgentRunStep(kind: .diagnostic, status: .finished)
            step.diagnostic = diagnostic
            steps.append(step)
        case .toolStarted(let callID, let name, let arguments):
            var step = AgentRunStep(kind: .tool)
            step.callID = callID
            step.toolName = name
            step.arguments = arguments
            steps.append(step)
        case .toolFinished(let callID, let name, let summary, let isError):
            let index = steps.lastIndex { $0.kind == .tool && $0.callID == callID && $0.status == .running }
            if let index {
                steps[index].status = isError ? .failed : .finished
                steps[index].outputSummary = summary
            } else {
                var step = AgentRunStep(kind: .tool, status: isError ? .failed : .finished)
                step.callID = callID
                step.toolName = name
                step.outputSummary = summary
                steps.append(step)
            }
        case .contextCompacted(let before, let after):
            var step = AgentRunStep(kind: .compaction, status: .finished)
            step.beforeTokens = before
            step.afterTokens = after
            steps.append(step)
        case .usage(let usage):
            hasUsage = true
            self.usage = self.usage.adding(usage)
        case .runFinished(let outcome):
            finishTurn()
            usage = outcome.totalUsage
            hasUsage = hasUsage || usage.inputTokens != 0 || usage.outputTokens != 0
            var step = AgentRunStep(kind: .stop, status: .finished)
            step.stopReason = outcome.stopReason
            steps.append(step)
        case .textDelta, .modelContent: break
        }
    }

    private mutating func finishTurn() {
        for index in steps.indices where steps[index].kind == .turn && steps[index].status == .running {
            steps[index].status = .finished
        }
    }
}
