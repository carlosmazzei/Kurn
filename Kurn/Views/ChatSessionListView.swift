//
//  ChatSessionListView.swift
//  Kurn
//
//  The "past conversations" sheet for "chat with your meetings" — the same
//  history list Claude's own mobile app offers: reopen a saved conversation
//  or delete one, scoped to whichever `MeetingChatView` opened it (a single
//  meeting's own conversations, or the library-wide "Ask" ones).
//
//  Takes a snapshot `sessions` array rather than a live `@Query` so a row
//  removed here disappears immediately without waiting on a SwiftData
//  re-fetch; `onDelete` still does the actual persistence, and reports
//  whether it deleted anything (the open conversation is refused while its
//  reply is still running), so a refused row stays in the list.
//

import SwiftUI

struct ChatSessionListView: View {
    @State private var sessions: [ChatSession]
    let currentSessionID: UUID?
    let onSelect: (ChatSession) -> Void
    let onDelete: (ChatSession) -> Bool
    let onRename: (ChatSession, String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The conversation being renamed and the title being typed (NH09).
    @State private var renaming: ChatSession?
    @State private var newTitle = ""

    init(
        sessions: [ChatSession],
        currentSessionID: UUID?,
        onSelect: @escaping (ChatSession) -> Void,
        onDelete: @escaping (ChatSession) -> Bool,
        onRename: @escaping (ChatSession, String) -> Void = { _, _ in }
    ) {
        self._sessions = State(initialValue: sessions)
        self.currentSessionID = currentSessionID
        self.onSelect = onSelect
        self.onDelete = onDelete
        self.onRename = onRename
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        NSLocalizedString("chat.history.empty.title", comment: "No saved conversations title"),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(NSLocalizedString("chat.history.empty.subtitle", comment: "No saved conversations subtitle"))
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            row(for: session)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            // Typing a title needs a text field, which only the system alert offers.
            .alert(NSLocalizedString("chat.history.rename", comment: "Rename conversation"),
                   isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(NSLocalizedString("chat.history.rename_placeholder", comment: "Conversation title"), text: $newTitle)
                Button(NSLocalizedString("common.save", comment: "Save")) {
                    if let renaming { onRename(renaming, newTitle) }
                    renaming = nil
                }
                Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) { renaming = nil }
            }
            .navigationTitle(NSLocalizedString("chat.history.title", comment: "Chat history sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
    }

    private func row(for session: ChatSession) -> some View {
        Button {
            onSelect(session)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(Theme.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(Theme.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if session.id == currentSessionID {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(session.id == currentSessionID ? .isSelected : [])
        .contextMenu {
            Button {
                newTitle = session.title
                renaming = session
            } label: {
                Label(NSLocalizedString("chat.history.rename", comment: "Rename conversation"), systemImage: "pencil")
            }
        }
    }

    /// Hands each deletion to `onDelete` for the actual SwiftData delete +
    /// save, then removes from this view's snapshot only the rows it deleted.
    private func delete(at offsets: IndexSet) {
        let deleted = IndexSet(offsets.filter { onDelete(sessions[$0]) })
        sessions.remove(atOffsets: deleted)
    }
}
