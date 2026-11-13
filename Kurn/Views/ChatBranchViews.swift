import SwiftUI

/// The branch actions a shown question offers (NH09), handed to `MeetingChatTurnView`.
struct ChatTurnBranchActions {
    var versions: ChatBranchPresentation.Alternatives?
    var label: String?
    var isEnabled: Bool
    var showVersion: (Int) -> Void
    var fork: () -> Void
    var editLabel: () -> Void
}

/// "‹ 2 of 3 ›" under a question asked more than once in the same place: moves between its
/// versions, each opening its branch where it was left.
struct ChatVersionSwitcher: View {
    let versions: ChatBranchPresentation.Alternatives
    let isEnabled: Bool
    let showVersion: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { showVersion(-1) } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .disabled(!isEnabled || versions.entryID(offset: -1) == nil)
            .accessibilityLabel(NSLocalizedString("chat.branch.previous", comment: "Previous version of a question"))
            Text(Self.position(versions))
                .font(Theme.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
            Button { showVersion(1) } label: {
                Image(systemName: "chevron.right")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .disabled(!isEnabled || versions.entryID(offset: 1) == nil)
            .accessibilityLabel(NSLocalizedString("chat.branch.next", comment: "Next version of a question"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.branch.versions")
    }

    static func position(_ versions: ChatBranchPresentation.Alternatives) -> String {
        String(format: NSLocalizedString("chat.branch.position", comment: "Version n of m"), versions.index + 1, versions.count)
    }
}

/// A turn's label, in words beside a bookmark glyph.
struct ChatTurnLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "bookmark.fill")
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .accessibilityLabel(String(format: NSLocalizedString("chat.branch.label_value", comment: "Turn label"), text))
    }
}
