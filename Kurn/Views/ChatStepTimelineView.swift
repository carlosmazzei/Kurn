import KurnCore
import SwiftUI

struct ChatStepTimelineView: View {
    let steps: [ChatAgentStep]
    let isRunning: Bool
    let meetingTitles: [UUID: String]
    let documentTitles: [UUID: String]
    @State private var expanded = false

    private var visibleSteps: [ChatAgentStep] { ChatStepPresentation.visibleSteps(steps) }

    var body: some View {
        if !visibleSteps.isEmpty {
            Group {
                if isRunning { rows }
                else {
                    DisclosureGroup(isExpanded: $expanded) {
                        rows
                    } label: {
                        Text(ChatStepPresentation.countLabel(visibleSteps.count) { NSLocalizedString($0, comment: "Step count") })
                            .font(.subheadline)
                            .frame(minHeight: 44, alignment: .leading)
                    }
                }
            }
            .accessibilityIdentifier("chat.steps")
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(visibleSteps) { step in
                ChatStepRow(step: step, meetingTitles: meetingTitles, documentTitles: documentTitles)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ChatStepRow: View {
    let step: ChatAgentStep
    let meetingTitles: [UUID: String]
    let documentTitles: [UUID: String]

    private var presentation: ChatStepPresentation {
        ChatStepPresentation(step: step, meetingTitles: meetingTitles, documentTitles: documentTitles)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
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
