import AgentHarness
import Foundation

/// A run as the chat shows it, in the order it happened (Claude Code-style): the model's
/// reasoning, the narration it wrote beside tool calls, and each tool call with its result line.
/// Context, diagnostic and turn steps are technical detail and stay in `details`.
struct ChatActivityPresentation: Equatable {
    enum Entry: Equatable, Identifiable {
        /// Reasoning text (empty when the provider kept it private), its duration when it was
        /// timed live, and whether it is still being written.
        case thinking(id: UUID, text: String, seconds: Int?, isRunning: Bool)
        case narration(id: UUID, text: String)
        case tool(id: UUID, step: AgentRunStep, result: String?)
        /// A context compaction or a limit the run reached, in its place in the sequence.
        case notice(id: UUID, step: AgentRunStep)

        var id: UUID {
            switch self {
            case .thinking(let id, _, _, _), .narration(let id, _), .tool(let id, _, _), .notice(let id, _): id
            }
        }
    }

    let entries: [Entry]
    /// What stays behind "Details": the context resolution and diagnostics.
    let details: [AgentRunStep]

    /// A tool's result line keeps one line of its summary.
    static let resultLineLimit = 140

    init(steps: [AgentRunStep]) {
        var entries: [Entry] = []
        var details: [AgentRunStep] = []
        for step in steps {
            switch step.kind {
            case .thinking:
                let seconds = step.duration.map { max(1, Int($0.rounded())) }
                entries.append(.thinking(id: step.id, text: step.text ?? "", seconds: seconds, isRunning: step.status == .running))
            case .narration:
                if let text = step.text, !text.isEmpty { entries.append(.narration(id: step.id, text: text)) }
            case .tool:
                entries.append(.tool(id: step.id, step: step, result: Self.resultLine(step.outputSummary)))
            case .compaction:
                entries.append(.notice(id: step.id, step: step))
            case .diagnostic where step.diagnostic?.kind == .limitReached:
                entries.append(.notice(id: step.id, step: step))
            case .stop where step.stopReason != .completed:
                entries.append(.notice(id: step.id, step: step))
            case .context, .diagnostic:
                details.append(step)
            case .turn, .stop:
                continue
            }
        }
        self.entries = entries
        self.details = details
    }

    var isEmpty: Bool { entries.isEmpty && details.isEmpty }

    /// The first non-empty line of a tool's output summary, bounded.
    static func resultLine(_ summary: String?) -> String? {
        guard let line = summary?.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.count > resultLineLimit ? String(line.prefix(resultLineLimit)) + "…" : line
    }

    /// The label of a reasoning entry: "Thinking…" while it runs, "Thought for N s" once timed,
    /// "Reasoning" when it was restored without timing.
    static func thinkingLabel(seconds: Int?, isRunning: Bool, localize: (String) -> String) -> String {
        if isRunning { return localize("chat.activity.thinking") }
        guard let seconds else { return localize("chat.activity.reasoning") }
        return String(format: localize("chat.activity.thought_for"), seconds)
    }

    /// The live status line's activity: reasoning while a reasoning entry is open, otherwise the
    /// phase's own wording (`ChatRunPhase.statusText` keeps compaction, retry and stop).
    static func statusKey(phase: ChatRunPhase, steps: [AgentRunStep]) -> String? {
        switch phase {
        case .compacting, .retryWaiting, .cancelling, .idle: return nil
        case .preparing: return "chat.activity.preparing"
        case .executingTools: return "chat.activity.using_tools"
        case .streaming:
            let reasoning = steps.last(where: { $0.kind == .thinking })?.status == .running
            return reasoning ? "chat.activity.thinking" : "chat.activity.writing"
        }
    }

    /// Output tokens so far, compact ("1.2k tokens"), for the live status line.
    static func tokenText(_ outputTokens: Int, localize: (String) -> String) -> String? {
        guard outputTokens > 0 else { return nil }
        let value = outputTokens >= 1_000
            ? (Double(outputTokens) / 1_000).formatted(.number.precision(.fractionLength(1))) + "k"
            : String(outputTokens)
        return String(format: localize("chat.activity.tokens"), value)
    }
}
