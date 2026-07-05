//
//  TagPickerView.swift
//  Kurn
//
//  Sheet for adding or removing tags on a meeting. Lists existing tags with
//  toggle selection and offers inline creation of new tags.
//

import SwiftData
import SwiftUI

struct TagPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let meeting: Meeting

    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var newTagName = ""
    @State private var pendingDelete: Tag?
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
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
        .kurnDialog(
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
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
    }

    private func tagRow(_ tag: Tag) -> some View {
        let isSelected = meeting.tags.contains(where: { $0.id == tag.id })
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
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = tag
            } label: {
                Label(NSLocalizedString("tag.delete", comment: "Delete"), systemImage: "trash")
            }
        }
    }

    private func toggleTag(_ tag: Tag) {
        if let index = meeting.tags.firstIndex(where: { $0.id == tag.id }) {
            meeting.tags.remove(at: index)
        } else {
            meeting.tags.append(tag)
        }
        saveError = modelContext.saveOrError()
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let existing = allTags.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            if !meeting.tags.contains(where: { $0.id == existing.id }) {
                meeting.tags.append(existing)
                saveError = modelContext.saveOrError()
            }
        } else {
            let tag = Tag(name: name)
            modelContext.insert(tag)
            meeting.tags.append(tag)
            saveError = modelContext.saveOrError()
        }
        newTagName = ""
    }

    private func deleteTag(_ tag: Tag) {
        modelContext.delete(tag)
        saveError = modelContext.saveOrError()
    }
}
