import AgentHarness
import SwiftUI

/// The live status line while the agent works, Claude Code-style: what it is doing, for how long
/// and how many tokens it has written ("✻ Thinking… 12 s · 1.2k tokens"). The wording comes from
/// `ChatActivityPresentation` and `ChatRunPhase`.
struct ChatRunStatusLine: View {
    let phase: ChatRunPhase
    let retryDelaySeconds: Double?
    let steps: [AgentRunStep]
    let outputTokens: Int?
    let startedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func localize(_ key: String) -> String { NSLocalizedString(key, comment: "Live run status") }

    var body: some View {
        let activity = ChatActivityPresentation.statusKey(phase: phase, steps: steps).map(localize)
            ?? phase.statusText(retryDelaySeconds: retryDelaySeconds)
        let tokens = outputTokens.flatMap { ChatActivityPresentation.tokenText($0, localize: localize) }
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.caption)
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text(activity)
                .font(Theme.footnote.italic())
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("chat.run_status")
            if let startedAt {
                Text(startedAt, style: .timer)
                    .font(Theme.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            if let tokens {
                Text(verbatim: "· " + tokens)
                    .font(Theme.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityIdentifier("chat.live_usage")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
