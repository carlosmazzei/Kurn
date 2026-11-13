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
    public var toolProgress: AgentToolProgress?
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
        case .toolProgress(let invocation, let progress):
            if let index = steps.lastIndex(where: { $0.kind == .tool && $0.callID == invocation.callID && $0.status == .running }) {
                steps[index].toolProgress = progress
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
        case .textDelta, .modelContent, .messageAppended, .requestStarted, .invocationRegistered: break
        }
    }

    private mutating func finishTurn() {
        for index in steps.indices where steps[index].kind == .turn && steps[index].status == .running {
            steps[index].status = .finished
        }
    }
}

extension AgentRunTrace {
    /// Rebuilds the trace of one run from its canonical session entries (NH05): the entries an
    /// `AgentSession` wrote with `runID` metadata, in commit order. Each assistant message opens a
    /// turn and starts its tool calls, each tool result finishes its call, each `agent.usage.v1`
    /// adds its usage and `agent.run-end.v1` adds the stop reason it recorded. Only what was
    /// committed is shown: a tool's output summary is a live event, not part of the message, so a
    /// restored call has none, and nothing is inferred. A run cut off before its end entry ends
    /// with no running step: an unanswered call reads as failed. `nil` when no entry has `runID`.
    public static func restoring(run runID: String, from entries: [AgentSessionEntry]) -> AgentRunTrace? {
        let run = entries.filter { $0.runID == runID }.sorted { $0.ordinal < $1.ordinal }
        guard !run.isEmpty else { return nil }
        var trace = AgentRunTrace()
        var turn = 0
        for entry in run {
            switch entry.payload {
            case .message(.content(let message)) where message.role == .assistant:
                // Zero-based, like the harness's own `turnStarted`.
                trace.apply(.turnStarted(index: turn))
                turn += 1
                for call in message.toolCalls {
                    trace.apply(.toolStarted(callID: call.id, name: call.name, arguments: call.arguments))
                }
            case .message(.tool(let result)):
                trace.restoreResult(callID: result.invocation.callID, name: result.invocation.toolName, isError: result.isError)
            case .custom(type: "agent.usage.v1", data: .object(let fields)):
                trace.apply(.usage(AgentUsage(inputTokens: count(fields["inputTokens"]) ?? 0,
                                              outputTokens: count(fields["outputTokens"]) ?? 0,
                                              reasoningTokens: count(fields["reasoningTokens"]))))
            case .custom(type: "agent.run-end.v1", data: .object(let fields)):
                if case .string(let raw)? = fields["stopReason"], let reason = AgentRunStopReason(rawValue: raw) {
                    var step = AgentRunStep(kind: .stop, status: .finished)
                    step.stopReason = reason
                    trace.steps.append(step)
                }
            default: break
            }
        }
        trace.closeRestored()
        return trace
    }

    /// A token count as `AgentSession` writes it: a whole, non-negative JSON number.
    private static func count(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite, number >= 0, number <= Double(Int32.max),
              number.rounded() == number else { return nil }
        return Int(number)
    }

    private mutating func restoreResult(callID: String, name: String, isError: Bool) {
        if let index = steps.lastIndex(where: { $0.kind == .tool && $0.callID == callID && $0.status == .running }) {
            steps[index].status = isError ? .failed : .finished
        } else {
            var step = AgentRunStep(kind: .tool, status: isError ? .failed : .finished)
            step.callID = callID
            step.toolName = name
            steps.append(step)
        }
    }

    private mutating func closeRestored() {
        for index in steps.indices where steps[index].status == .running {
            steps[index].status = steps[index].kind == .tool ? .failed : .finished
        }
    }
}

extension AgentSessionEntry {
    /// The run an `AgentSession` wrote this entry for, from its `runID` metadata; `nil` for an
    /// entry no run wrote, such as the host's presentation entries.
    public var runID: String? {
        guard case .object(let fields)? = metadata, case .string(let id)? = fields["runID"] else { return nil }
        return id
    }
}
