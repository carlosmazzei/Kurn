import SwiftUI

/// The branch actions a shown question offers (NH09), handed to `MeetingChatTurnView`.
struct ChatTurnBranchActions {
    var versions: ChatBranchPresentation.Alternatives?
    var label: String?
    var isEnabled: Bool
    var showVersion: (Int) -> Void
    var fork: () -> Void
    var editLabel: () -> Void
    /// Whether later answers leave this exchange out, and the action that switches it.
    var isLeftOut = false
    var setLeftOut: (Bool) -> Void = { _ in }
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

/// Every question of the conversation as a tree (NH09): the branch shown is marked, and choosing
/// another question opens its branch where it was left.
struct ChatBranchTreeView: View {
    let outline: ChatBranchOutline
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(outline.nodes) { node in
                Button {
                    if !node.isShown { open(node.id) }
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: node.isShown ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(node.isShown ? Theme.accent : Theme.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            if let label = node.label {
                                Text(label).font(Theme.caption2).foregroundStyle(Theme.textSecondary)
                            }
                            Text(node.text).lineLimit(2).foregroundStyle(Theme.textPrimary)
                        }
                    }
                    .padding(.leading, CGFloat(min(node.depth, 6)) * 16)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(node.isShown ? .isSelected : [])
                .accessibilityIdentifier("chat.branch.tree.node")
            }
            .navigationTitle(NSLocalizedString("chat.branch.tree", comment: "Every branch of the conversation"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
