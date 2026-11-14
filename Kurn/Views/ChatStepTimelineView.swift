import AgentHarness
import KurnCore
import SwiftUI

/// A run as it happened, Claude Code-style: the model's reasoning (one tappable line, its newest
/// lines streaming beneath it while it thinks), its narration, and each tool call with a `⎿`
/// result line, successive calls of one tool folded into one line. Once the reply is done the
/// whole activity folds into one summary line ("Thought for 12 s · 6 actions") that expands on
/// tap. The ordering and wording live in `ChatActivityPresentation`.
struct ChatStepTimelineView: View {
    let steps: [AgentRunStep]
    let isRunning: Bool
    let meetingTitles: [UUID: String]
    let documentTitles: [UUID: String]
    @State private var showsDetails = false
    @State private var expanded = false

    var body: some View {
        let activity = ChatActivityPresentation(steps: steps)
        if !activity.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if isRunning {
                    entries(activity)
                } else {
                    // A finished reply folds its whole activity into one line, as Claude Code does.
                    summaryButton(activity)
                    if expanded || activity.summary(localize: localize) == nil {
                        entries(activity)
                        details(activity)
                    }
                }
            }
            .accessibilityIdentifier("chat.steps")
        }
    }

    private func localize(_ key: String) -> String { NSLocalizedString(key, comment: "Agent activity") }

    @ViewBuilder
    private func summaryButton(_ activity: ChatActivityPresentation) -> some View {
        if let summary = activity.summary(localize: localize) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(summary)
                        .font(Theme.footnote)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Theme.textSecondary)
                .frame(minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint(localize("chat.activity.summary.hint"))
            .accessibilityIdentifier("chat.activity.summary")
        }
    }

    private func entries(_ activity: ChatActivityPresentation) -> some View {
        ForEach(activity.entries) { entry in
            switch entry {
            case .thinking(_, let text, let seconds, let running):
                ChatThinkingRow(text: text, seconds: seconds, isRunning: running)
            case .narration(_, let text):
                ChatNarrationRow(text: text)
            case .tool(_, let step, let result):
                ChatToolRow(step: step, result: result, meetingTitles: meetingTitles, documentTitles: documentTitles)
            case .toolGroup(_, let name, let grouped):
                ChatToolGroupRow(name: name, steps: grouped, meetingTitles: meetingTitles, documentTitles: documentTitles)
            case .notice(_, let step):
                ChatNoticeRow(step: step, meetingTitles: meetingTitles, documentTitles: documentTitles)
            }
        }
    }

    private func details(_ activity: ChatActivityPresentation) -> some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            VStack(alignment: .leading, spacing: 12) {
                if !steps.contains(where: { $0.contextResolution != nil }) {
                    Text(NSLocalizedString("chat.context.unknown", comment: "Legacy context origin"))
                        .font(.caption)
                }
                ForEach(activity.details) { step in
                    ChatStepRow(step: step, meetingTitles: meetingTitles, documentTitles: documentTitles)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Text(NSLocalizedString("chat.activity.details", comment: "Technical details of a reply"))
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(minHeight: 44, alignment: .leading)
        }
    }
}

/// One reasoning block: "Thinking…" with the text streaming beneath it, then "Thought for N s",
/// which expands to the full reasoning on tap. Reasoning a provider kept private shows the line alone.
private struct ChatThinkingRow: View {
    let text: String
    let seconds: Int?
    let isRunning: Bool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: String {
        ChatActivityPresentation.thinkingLabel(seconds: seconds, isRunning: isRunning) {
            NSLocalizedString($0, comment: "Model reasoning")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .symbolEffect(.pulse, isActive: isRunning && !reduceMotion)
                        .accessibilityHidden(true)
                    Text(label)
                        .font(Theme.footnote.italic())
                        .foregroundStyle(Theme.textSecondary)
                    if !text.isEmpty, !isRunning {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty || isRunning)
            .accessibilityHint(text.isEmpty || isRunning ? ""
                               : NSLocalizedString("chat.activity.reasoning.hint", comment: "Shows or hides the reasoning"))
            if !text.isEmpty, isRunning || expanded {
                // While it streams, only the newest lines; expanded, all of it.
                Text(text)
                    .font(Theme.footnote.italic())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(isRunning ? 2 : nil)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.separator).frame(width: 2).accessibilityHidden(true)
                    }
            }
        }
        .accessibilityIdentifier("chat.activity.thinking")
    }
}

/// What the model said beside its tool calls ("I'll search the budget meetings").
private struct ChatNarrationRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Theme.textSecondary)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("chat.activity.narration")
    }
}

/// A tool call: a status dot and its title, then a `⎿` line with its result. Tapping shows the
/// arguments and the full result.
struct ChatToolRow: View {
    let step: AgentRunStep
    let result: String?
    let meetingTitles: [UUID: String]
    let documentTitles: [UUID: String]
    @State private var expanded = false

    private var presentation: ChatStepPresentation {
        ChatStepPresentation(step: step, meetingTitles: meetingTitles, documentTitles: documentTitles)
    }

    private var dotColor: Color { ChatToolRow.dotColor(step.status) }

    static func dotColor(_ status: AgentRunStep.Status) -> Color {
        switch status {
        case .running: Theme.info
        case .finished: Theme.success
        case .failed: Color(uiColor: .systemRed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(dotColor).frame(width: 7, height: 7).accessibilityHidden(true)
                    Image(systemName: presentation.symbol)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                    Text(presentation.title { NSLocalizedString($0, comment: "Agent step") })
                        .font(Theme.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if step.status == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel(NSLocalizedString("chat.step.running", comment: "Running"))
                    }
                }
                .frame(minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint(NSLocalizedString("chat.activity.tool.hint", comment: "Shows the tool's arguments and result"))
            if step.status == .failed {
                resultLine(NSLocalizedString("chat.step.failed", comment: "Tool failed"), color: Color(uiColor: .systemRed))
            } else if let result {
                resultLine(result, color: Theme.textSecondary)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let arguments = step.argumentsSummary { ChatStepDetail(key: "chat.steps.arguments", text: arguments) }
                    if let output = step.outputSummary { ChatStepDetail(key: "chat.steps.output", text: output) }
                }
                .padding(.leading, 23)
            }
        }
        .accessibilityIdentifier("chat.activity.tool")
    }

    private func resultLine(_ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "⎿")
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(color)
                .lineLimit(2)
        }
        .font(Theme.caption)
        .padding(.leading, 15)
    }
}

/// A compaction, or a limit the run reached, in its place in the sequence.
private struct ChatNoticeRow: View {
    let step: AgentRunStep
    let meetingTitles: [UUID: String]
    let documentTitles: [UUID: String]

    var body: some View {
        let presentation = ChatStepPresentation(step: step, meetingTitles: meetingTitles, documentTitles: documentTitles)
        Label(presentation.title { NSLocalizedString($0, comment: "Agent step") }, systemImage: presentation.symbol)
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A labelled, monospaced preview of a step's arguments or output.
private struct ChatStepDetail: View {
    let key: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString(key, comment: "Step detail")).font(.caption.bold())
            Text(ChatStepPresentation.preview(text))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ChatStepRow: View {
    let step: AgentRunStep
    let meetingTitles: [UUID: String]
    let documentTitles: [UUID: String]

    private var presentation: ChatStepPresentation {
        ChatStepPresentation(step: step, meetingTitles: meetingTitles, documentTitles: documentTitles)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if let resolution = step.contextResolution {
                    contextDetails(resolution)
                }
                if let diagnostic = step.diagnostic {
                    Text(ChatContextPresentation.diagnosticDetails(diagnostic) { NSLocalizedString($0, comment: "Harness metric") })
                        .font(.caption)
                        .textSelection(.enabled)
                }
                if let arguments = step.argumentsSummary {
                    detail("chat.steps.arguments", text: arguments)
                }
                if let output = step.outputSummary { detail("chat.steps.output", text: output) }
                if let before = step.beforeTokens, let after = step.afterTokens {
                    Text(String(format: NSLocalizedString("chat.steps.compaction.detail", comment: "Context tokens"), before, after))
                        .font(.caption)
                }
            }
            .padding(.leading, 24)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: step.status == .failed ? "exclamationmark.circle" : presentation.symbol)
                    .foregroundStyle(step.status == .failed ? Color(uiColor: .systemRed) : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title { NSLocalizedString($0, comment: "Agent step") })
                        .fixedSize(horizontal: false, vertical: true)
                    if step.status == .failed {
                        Text(NSLocalizedString("chat.step.failed", comment: "Tool failed"))
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                    }
                }
                if step.status == .running {
                    ProgressView().accessibilityLabel(NSLocalizedString("chat.step.running", comment: "Running"))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("chat.step.\(step.id.uuidString)")
    }

    private func contextDetails(_ resolution: AgentHarness.AgentContextResolution) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString(ChatContextPresentation.sourceKey(resolution), comment: "Context origin"))
            if let refresh = resolution.metadataRefresh {
                Text(NSLocalizedString("chat.context.refresh.\(refresh.rawValue)", comment: "Metadata refresh outcome"))
            }
            Text(String(format: NSLocalizedString("chat.context.tokens", comment: "Context capacity"), resolution.contextWindowTokens))
            Text(NSLocalizedString("chat.context.kind.\(resolution.limitKind.rawValue)", comment: "Context limit kind"))
            if let fetchedAt = resolution.fetchedAt {
                Text(fetchedAt, format: .dateTime.year().month().day().hour().minute())
            }
            if let version = resolution.catalogVersion {
                Text(String(format: NSLocalizedString("chat.context.catalog_version", comment: "Catalog version"), version))
            }
            if let capabilities = resolution.capabilities {
                ForEach(ChatContextPresentation.capabilityLines(capabilities) {
                    NSLocalizedString($0, comment: "Model capability")
                }, id: \.self) { Text($0) }
            }
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    private func detail(_ key: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString(key, comment: "Step detail")).font(.caption.bold())
            Text(ChatStepPresentation.preview(text))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
