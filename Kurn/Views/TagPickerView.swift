//
//  TagPickerView.swift
//  Kurn
//
//  Sheet for adding or removing tags on a meeting. Lists existing tags with
//  toggle selection and offers inline creation of new tags.
//

import SwiftData
import KurnCore
import SwiftUI

struct TagPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The meetings the toggles apply to; one for the context-menu entry,
    /// every selected meeting for the selection-mode Tags button.
    let meetings: [Meeting]
    /// Called after a successful toggle in bulk mode so the caller can leave
    /// selection mode; single-meeting use leaves it nil and stays open.
    var onApplied: (() -> Void)?

    init(meetings: [Meeting], onApplied: (() -> Void)? = nil) {
        self.meetings = meetings
        self.onApplied = onApplied
    }

    /// Convenience for the single-meeting context-menu entry.
    init(meeting: Meeting) {
        self.init(meetings: [meeting])
    }

    /// 2 when every meeting carries the tag, 0 when none does, 1 for a mixed
    /// selection (shown as `minus.circle`; the first tap turns it fully on).
    private func tagState(_ tag: Tag) -> Int {
        let count = meetings.count { $0.tags.contains(where: { $0.id == tag.id }) }
        return count == meetings.count ? 2 : (count == 0 ? 0 : 1)
    }

    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var newTagName = ""
    @State private var pendingDelete: Tag?
    @State private var editingTag: Tag?
    /// Set when a tag add/remove/create/delete save fails, surfaced via `.errorAlert`.
    @State private var saveError: AppError?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if allTags.isEmpty {
                        Text(NSLocalizedString("tag.empty", comment: "No tags yet"))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(allTags) { tag in
                            tagRow(tag)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("tag.select", comment: "Select tags"))
                } footer: {
                    Text(NSLocalizedString("tag.delete.message", comment: "Deleting removes from all meetings"))
                }

                Section(NSLocalizedString("tag.new", comment: "New tag")) {
                    HStack(spacing: 12) {
                        TextField(
                            NSLocalizedString("tag.name_placeholder", comment: "Tag name"),
                            text: $newTagName
                        )
                        Button {
                            createTag()
                        } label: {
                            Text(NSLocalizedString("tag.add", comment: "Add"))
                        }
                        .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("tag.title", comment: "Tags"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) {
                        dismiss()
                        onApplied?()
                    }
                }
            }
        }
        .sheet(item: $editingTag) { tag in
            TagEditorView(tag: tag)
        }
        .kurnDialog(
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.destructive,
            title: NSLocalizedString("tag.delete.confirm", comment: "Delete tag?"),
            message: NSLocalizedString("tag.delete.message", comment: "Removed from all meetings"),
            primaryTitle: NSLocalizedString("tag.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                if let tag = pendingDelete { deleteTag(tag) }
                pendingDelete = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: { pendingDelete = nil }
        )
        .errorAlert($saveError)
        // A short tag list is a quick toggle task; a large tag library can
        // still grow into `.large` instead of always opening full-height.
        .presentationDetents([.medium, .large])
    }

    private func tagRow(_ tag: Tag) -> some View {
        let state = tagState(tag)
        return Button {
            toggleTag(tag)
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color(hex: tag.colorHex))
                    .frame(width: 10, height: 10)
                Text(tag.name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                switch state {
                case 2:
                    Image(systemName: "checkmark")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.link)
                        .accessibilityHidden(true)
                case 1:
                    Image(systemName: "minus.circle")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                default:
                    EmptyView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state == 2 ? .isSelected : [])
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = tag
            } label: {
                Label(NSLocalizedString("tag.delete", comment: "Delete"), systemImage: "trash")
            }
            Button {
                editingTag = tag
            } label: {
                Label(NSLocalizedString("tag.edit", comment: "Edit"), systemImage: "pencil")
            }
            .tint(Theme.info)
        }
    }

    /// Fully on → remove from every meeting; off or mixed → add to every
    /// meeting that lacks it.
    private func toggleTag(_ tag: Tag) {
        let wasFullyOn = tagState(tag) == 2
        for meeting in meetings {
            if let index = meeting.tags.firstIndex(where: { $0.id == tag.id }) {
                if wasFullyOn { meeting.tags.remove(at: index) }
            } else {
                meeting.tags.append(tag)
            }
        }
        saveError = modelContext.saveOrError()
    }

    private func createTag() {
        do throws(AppError) {
            for meeting in meetings {
                try MeetingLibrary(context: modelContext).attachTag(named: newTagName, to: meeting)
            }
        } catch {
            saveError = error
        }
        newTagName = ""
    }

    private func deleteTag(_ tag: Tag) {
        do throws(AppError) {
            try MeetingLibrary(context: modelContext).deleteTag(tag)
        } catch {
            saveError = error
        }
    }
}
