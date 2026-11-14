import Foundation

public struct AgentRunStep: Codable, Sendable, Equatable, Identifiable {
    /// `thinking` is the model's visible reasoning, `narration` the text it wrote beside tool calls.
    public enum Kind: String, Codable, Sendable { case turn, tool, compaction, stop, context, diagnostic, thinking, narration }
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
    /// The reasoning or narration text, bounded by `AgentRunTrace.maxStepTextScalars`.
    public var text: String?
    /// When a reasoning block started and ended, while the run was observed live; a restored run has none.
    public var startedAt: Date?
    public var finishedAt: Date?
    public var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }
    public var argumentsSummary: String? { arguments.flatMap { try? $0.encodedString() } }

    public init(kind: Kind, status: Status = .running) {
        id = UUID()
        self.kind = kind
        self.status = status
    }
}

public struct AgentRunTrace: Sendable, Equatable {
    /// Reasoning and narration kept per step for display; the canonical messages keep it all.
    public static let maxStepTextScalars = 8_000

    public private(set) var steps: [AgentRunStep] = []
    public private(set) var usage = AgentUsage()
    public private(set) var hasUsage = false
    /// Running reasoning steps by the content block streaming into them.
    private var thinkingSteps: [String: Int] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public static func == (lhs: AgentRunTrace, rhs: AgentRunTrace) -> Bool {
        lhs.steps == rhs.steps && lhs.usage == rhs.usage && lhs.hasUsage == rhs.hasUsage
    }

    public mutating func apply(_ event: AgentEvent) {
        switch event {
        case .runStarted:
            steps = []
            usage = AgentUsage()
            hasUsage = false
            thinkingSteps = [:]
        case .turnStarted(let index):
            finishThinking()
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
            finishThinking()
            finishTurn()
            usage = outcome.totalUsage
            hasUsage = hasUsage || usage.inputTokens != 0 || usage.outputTokens != 0
            var step = AgentRunStep(kind: .stop, status: .finished)
            step.stopReason = outcome.stopReason
            steps.append(step)
        case .modelContent(let content):
            applyContent(content)
        case .messageAppended(.content(let message)) where message.role == .assistant:
            finishThinking()
            appendNarration(of: message)
        case .textDelta, .messageAppended, .requestStarted, .invocationRegistered: break
        }
    }

    /// Reasoning streams into its own step while its block is open; any other block, the finished
    /// message or a failure closes it. The finished message's text replaces what streamed, and a
    /// reasoning block that never streamed (a provider that sends it whole) is added from it.
    private mutating func applyContent(_ content: AgentContentEvent) {
        switch content {
        case .blockStarted(_, let block):
            guard case .thinking(let text, _, _, _) = block.content else { finishThinking(keepingBlocks: true); return }
            var step = AgentRunStep(kind: .thinking)
            step.text = Self.bounded(text ?? "")
            step.startedAt = now()
            steps.append(step)
            thinkingSteps[block.id] = steps.count - 1
        case .blockDelta(let id, .thinking(let delta)):
            guard let index = thinkingSteps[id], steps.indices.contains(index) else { return }
            steps[index].text = Self.bounded((steps[index].text ?? "") + delta)
        case .blockDelta, .blockUpdated: break
        case .messageFinished(let message):
            // The finished message is authoritative: streamed blocks are matched by ID, then in
            // order (a final message may rename them), take its text even when empty, and a streamed
            // block it dropped is removed. Reasoning it sent whole is added.
            let streamed = thinkingSteps.values.sorted()
            var unmatched = streamed
            var kept = Set<Int>()
            for block in message.blocks {
                guard case .thinking(let text, _, _, _) = block.content else { continue }
                let index = thinkingSteps[block.id].flatMap { unmatched.contains($0) ? $0 : nil } ?? unmatched.first
                if let index, steps.indices.contains(index) {
                    unmatched.removeAll { $0 == index }
                    kept.insert(index)
                    steps[index].text = Self.bounded(text ?? "")
                } else {
                    var step = AgentRunStep(kind: .thinking, status: .finished)
                    step.text = Self.bounded(text ?? "")
                    steps.append(step)
                }
            }
            finishThinking()
            for index in streamed.filter({ !kept.contains($0) }).sorted(by: >) where steps.indices.contains(index) {
                steps.remove(at: index)
            }
        case .failed:
            finishThinking()
        }
    }

    /// Closes the open reasoning steps. Their blocks stay known until the message finishes, so its
    /// final text still lands on the step that streamed it.
    private mutating func finishThinking(keepingBlocks: Bool = false) {
        let finished = now()
        for index in thinkingSteps.values where steps.indices.contains(index) && steps[index].status == .running {
            steps[index].status = .finished
            steps[index].finishedAt = finished
        }
        if !keepingBlocks { thinkingSteps = [:] }
    }

    /// Text an assistant wrote in a turn that also calls tools is narration ("I'll search the
    /// budget meetings"), shown in order with the calls; a reply without calls is the answer.
    private mutating func appendNarration(of message: AgentContentMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.toolCalls.isEmpty, !text.isEmpty else { return }
        var step = AgentRunStep(kind: .narration, status: .finished)
        step.text = Self.bounded(text)
        steps.append(step)
    }

    static func bounded(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard scalars.count > maxStepTextScalars else { return text }
        return String(String.UnicodeScalarView(scalars.prefix(maxStepTextScalars))) + "…"
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
        var counted = Set<String>()
        for entry in run {
            switch entry.payload {
            case .message(.content(let message)) where message.role == .assistant:
                // Zero-based, like the harness's own `turnStarted`.
                trace.apply(.turnStarted(index: turn))
                turn += 1
                trace.restoreReasoning(of: message)
                for call in message.toolCalls {
                    trace.apply(.toolStarted(callID: call.id, name: call.name, arguments: call.arguments))
                }
            case .message(.tool(let result)):
                trace.restoreResult(callID: result.invocation.callID, name: result.invocation.toolName, isError: result.isError)
            case .custom(type: "agent.usage.v1", data: .object(let fields))
                where AgentUsageEntry.isFirst(.object(fields), of: runID, among: &counted):
                trace.apply(.usage(AgentUsage(inputTokens: count(fields["inputTokens"]) ?? 0,
                                              outputTokens: count(fields["outputTokens"]) ?? 0,
                                              reasoningTokens: count(fields["reasoningTokens"]),
                                              cacheReadTokens: count(fields["cacheReadTokens"]),
                                              cacheWriteTokens: count(fields["cacheWriteTokens"]))))
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

    /// The committed reasoning blocks and narration of a restored assistant message, untimed.
    private mutating func restoreReasoning(of message: AgentContentMessage) {
        for block in message.blocks {
            guard case .thinking(let text, _, _, _) = block.content else { continue }
            var step = AgentRunStep(kind: .thinking, status: .finished)
            step.text = Self.bounded(text ?? "")
            steps.append(step)
        }
        appendNarration(of: message)
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

    /// The command a run-start entry was written for (`AgentSession.start(commandID:)`), if any.
    public var commandID: String? {
        guard case .custom(type: "agent.run-start.v1", data: .object(let fields)) = payload,
              case .string(let id)? = fields["commandID"] else { return nil }
        return id
    }
}

/// `agent.usage.v1` entries name the request they belong to (`requestID`), so one request's usage
/// counts once however often it was recorded. Entries written before requests were named carry
/// none and each counts.
enum AgentUsageEntry {
    static func isFirst(_ data: JSONValue, of runID: String, among counted: inout Set<String>) -> Bool {
        guard case .object(let fields) = data, case .string(let requestID)? = fields["requestID"] else { return true }
        return counted.insert(runID + "\u{0}" + requestID).inserted
    }
}
