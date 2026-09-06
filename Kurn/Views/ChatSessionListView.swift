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
//  re-fetch; `onDelete` still does the actual persistence.
//

import SwiftUI

struct ChatSessionListView: View {
    @State private var sessions: [ChatSession]
    let currentSessionID: UUID?
    let onSelect: (ChatSession) -> Void
    let onDelete: (ChatSession) -> Void

    @Environment(\.dismiss) private var dismiss

    init(
        sessions: [ChatSession],
        currentSessionID: UUID?,
        onSelect: @escaping (ChatSession) -> Void,
        onDelete: @escaping (ChatSession) -> Void
    ) {
        self._sessions = State(initialValue: sessions)
        self.currentSessionID = currentSessionID
        self.onSelect = onSelect
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(sessions) { session in
                            row(for: session)
                        }
                        .onDelete(perform: delete)
                    }
                }
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
    }

    /// Removes the row immediately (this view's own snapshot) and hands the
    /// deletion off to `onDelete` for the actual SwiftData delete + save.
    private func delete(at offsets: IndexSet) {
        for index in offsets { onDelete(sessions[index]) }
        sessions.remove(atOffsets: offsets)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(NSLocalizedString("chat.history.empty.title", comment: "No saved conversations title"))
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(NSLocalizedString("chat.history.empty.subtitle", comment: "No saved conversations subtitle"))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .accessibilityElement(children: .contain)
    }
}
