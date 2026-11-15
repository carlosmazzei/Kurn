import AgentHarness
import SwiftUI

/// The messages queued for the running reply (NH08), above the composer: each with what it is
/// (steering or after this task), an edit action that takes it back into the composer and a
/// remove action. Status is in words, never only in color.
struct ChatQueuedInputView: View {
    let queued: AgentInputQueue.Snapshot
    let edit: (AgentInputQueue.Item) -> Void
    let remove: (AgentInputQueue.Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(queued.steering + queued.followUp) { item in
                row(item)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.queue")
    }

    private func row(_ item: AgentInputQueue.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { edit(item) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.label(for: item.kind))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(item.text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Self.label(for: item.kind)): \(item.text)")
            .accessibilityHint(NSLocalizedString("chat.queue.edit", comment: "Edit queued message"))

            Button { remove(item) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("chat.queue.remove", comment: "Remove queued message"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    static func label(for kind: AgentInputQueue.Kind) -> String {
        switch kind {
        case .steering: NSLocalizedString("chat.queue.steering_label", comment: "Queued steering message")
        case .followUp: NSLocalizedString("chat.queue.follow_up_label", comment: "Queued follow-up message")
        }
    }
}
