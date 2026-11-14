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
        /// Consecutive calls of the same tool, shown as one line ("Read 3 transcripts").
        case toolGroup(id: UUID, name: String, steps: [AgentRunStep])
        /// A context compaction or a limit the run reached, in its place in the sequence.
        case notice(id: UUID, step: AgentRunStep)

        var id: UUID {
            switch self {
            case .thinking(let id, _, _, _), .narration(let id, _), .tool(let id, _, _), .toolGroup(let id, _, _),
                 .notice(let id, _): id
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
                // Successive calls of one tool fold into a group, as Claude Code shows "Read 3 files".
                let name = step.toolName ?? ""
                switch entries.last {
                case .tool(let id, let previous, _)? where previous.toolName == step.toolName:
                    entries[entries.count - 1] = .toolGroup(id: id, name: name, steps: [previous, step])
                case .toolGroup(let id, let groupName, let grouped)? where groupName == name:
                    entries[entries.count - 1] = .toolGroup(id: id, name: name, steps: grouped + [step])
                default:
                    entries.append(.tool(id: step.id, step: step, result: Self.resultLine(step.outputSummary)))
                }
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

    /// Tool calls in all entries, grouped or not.
    var actionCount: Int {
        entries.reduce(0) { count, entry in
            switch entry {
            case .tool: count + 1
            case .toolGroup(_, _, let steps): count + steps.count
            default: count
            }
        }
    }

    /// The one line a finished run folds into, e.g. "Thought for 12 s · 6 actions"; nil when it
    /// neither reasoned nor called a tool.
    func summary(localize: (String) -> String) -> String? {
        var parts: [String] = []
        var thoughts = 0
        var seconds: Int?
        for case .thinking(_, _, let timed, _) in entries {
            thoughts += 1
            if let timed { seconds = (seconds ?? 0) + timed }
        }
        if thoughts > 0 {
            parts.append(seconds.map { String(format: localize("chat.activity.thought_for"), $0) }
                         ?? localize("chat.activity.reasoning"))
        }
        if actionCount == 1 { parts.append(localize("chat.activity.actions.one")) }
        if actionCount > 1 { parts.append(String(format: localize("chat.activity.actions.count"), actionCount)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Tools whose groups have their own wording; any other tool uses the generic count.
    static let groupedTools: Set<String> = ["search", "read_transcript", "read_summary", "read_wiki", "read_attachment",
                                            "read_document", "list_sources"]

    static func groupTitle(name: String, count: Int, localize: (String) -> String) -> String {
        let key = groupedTools.contains(name) ? "chat.activity.group.\(name)" : "chat.activity.group.other"
        return String(format: localize(key), count)
    }

    /// What a group touched, compact: the first two meetings, queries or documents and how many
    /// more ("Budget review, Kickoff, +2"); nil when the calls name nothing.
    static func groupResult(_ steps: [AgentRunStep], meetingTitles: [UUID: String], documentTitles: [UUID: String]) -> String? {
        var names: [String] = []
        for step in steps {
            let presentation = ChatStepPresentation(step: step, meetingTitles: meetingTitles, documentTitles: documentTitles)
            // An unknown tool's parameter is its own name, which the group title already says.
            guard presentation.parameterKey != "chat.step.tool.unknown", let name = presentation.parameter,
                  !names.contains(name) else { continue }
            names.append(name)
        }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown), +\(names.count - 2)" : shown
    }

    /// The group's collapsed `⎿` line: what it touched, with a failure said in words ahead of it,
    /// never by colour alone.
    static func groupResultLine(_ steps: [AgentRunStep], failed: String, meetingTitles: [UUID: String],
                                documentTitles: [UUID: String]) -> String? {
        let names = groupResult(steps, meetingTitles: meetingTitles, documentTitles: documentTitles)
        guard groupStatus(steps) == .failed else { return names }
        return names.map { "\(failed) · \($0)" } ?? failed
    }

    /// A group is running while any call runs, failed when any failed, otherwise finished.
    static func groupStatus(_ steps: [AgentRunStep]) -> AgentRunStep.Status {
        if steps.contains(where: { $0.status == .running }) { return .running }
        if steps.contains(where: { $0.status == .failed }) { return .failed }
        return .finished
    }

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
