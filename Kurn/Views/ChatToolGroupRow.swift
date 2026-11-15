import AgentHarness
import SwiftUI

/// Successive calls of one tool as one line ("Read 3 transcripts") with a `⎿` line naming what
/// they touched ("Budget review, Kickoff, +1"). Tapping lists each call as its own row.
struct ChatToolGroupRow: View {
    let name: String
    let steps: [AgentRunStep]
    let meetingTitles: [UUID: String]
    let documentTitles: [UUID: String]
    @State private var expanded = false

    var body: some View {
        let status = ChatActivityPresentation.groupStatus(steps)
        let symbol = ChatStepPresentation(step: steps[0], meetingTitles: meetingTitles, documentTitles: documentTitles).symbol
        VStack(alignment: .leading, spacing: 3) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(ChatToolRow.dotColor(status)).frame(width: 7, height: 7).accessibilityHidden(true)
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                    Text(ChatActivityPresentation.groupTitle(name: name, count: steps.count) {
                        NSLocalizedString($0, comment: "Grouped tool calls")
                    })
                    .font(Theme.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                    if status == .running {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityLabel(NSLocalizedString("chat.step.running", comment: "Running"))
                    }
                }
                .frame(minHeight: 32, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint(NSLocalizedString("chat.activity.group.hint", comment: "Shows each call of the group"))
            if !expanded, let result = collapsedResult() {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "⎿")
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                    Text(result)
                        .foregroundStyle(status == .failed ? Color(uiColor: .systemRed) : Theme.textSecondary)
                        .lineLimit(1)
                }
                .font(Theme.caption)
                .padding(.leading, 15)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps) { step in
                        ChatToolRow(step: step, result: ChatActivityPresentation.resultLine(step.outputSummary),
                                    meetingTitles: meetingTitles, documentTitles: documentTitles)
                    }
                }
                .padding(.leading, 15)
            }
        }
        .accessibilityIdentifier("chat.activity.tool_group")
    }

    private func collapsedResult() -> String? {
        ChatActivityPresentation.groupResultLine(steps, failed: NSLocalizedString("chat.step.failed", comment: "Tool failed"),
                                                 meetingTitles: meetingTitles, documentTitles: documentTitles)
    }
}
