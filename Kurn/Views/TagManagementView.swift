//
//  TagManagementView.swift
//  Kurn
//
//  Settings screen for managing all user-defined tags: rename, recolor, merge,
//  delete. Deleting a tag detaches it from every meeting without deleting the
//  meetings themselves.
//

import SwiftData
import SwiftUI

struct TagManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Tag.name) private var tags: [Tag]

    @State private var newTagName = ""
    @State private var editingTag: Tag?
    @State private var pendingDelete: Tag?
    @State private var mergeTarget: Tag?
    @State private var mergeSource: Tag?
    /// Set when a tag create/delete/merge save fails, surfaced via `.errorAlert`.
    @State private var saveError: AppError?

    var body: some View {
        NavigationStack {
            List {
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

                Section {
                    if tags.isEmpty {
                        Text(NSLocalizedString("tag.empty", comment: "No tags yet"))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(tags) { tag in
                            tagRow(tag)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("tag.title", comment: "Tags"))
                } footer: {
                    Text(NSLocalizedString("tag.delete.message", comment: "Deleting removes from all meetings"))
                }
            }
            .navigationTitle(NSLocalizedString("tag.manage", comment: "Manage Tags"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
        .sheet(item: $editingTag) { tag in
            TagEditorView(tag: tag)
        }
        .sheet(item: $mergeSource) { source in
            TagMergeView(source: source, tags: tags) { target in
                merge(source: source, into: target)
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
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: tag.colorHex))
                .frame(width: 10, height: 10)
            Text(tag.name)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(tag.meetings.count)")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
        }
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
            Button {
                mergeSource = tag
            } label: {
                Label(
                    NSLocalizedString("tag.merge", comment: "Merge"),
                    systemImage: "arrow.merge"
                )
            }
            .tint(Theme.accent)
        }
    }

    private func createTag() {
        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !tags.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            newTagName = ""
            return
        }
        let tag = Tag(name: name)
        modelContext.insert(tag)
        saveError = modelContext.saveOrError()
        newTagName = ""
    }

    private func deleteTag(_ tag: Tag) {
        modelContext.delete(tag)
        saveError = modelContext.saveOrError()
    }

    private func merge(source: Tag, into target: Tag) {
        for meeting in source.meetings
        where !meeting.tags.contains(where: { $0.id == target.id }) {
            meeting.tags.append(target)
        }
        modelContext.delete(source)
        saveError = modelContext.saveOrError()
        mergeSource = nil
    }
}

/// Inline editor for a tag's name and color.
struct TagEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let tag: Tag

    @State private var name = ""
    @State private var colorHex = ""
    /// Set when saving the edited tag fails, so the failure surfaces.
    @State private var saveError: AppError?

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("tag.name_placeholder", comment: "Name")) {
                    TextField(
                        NSLocalizedString("tag.name_placeholder", comment: "Tag name"),
                        text: $name
                    )
                }
                Section(NSLocalizedString("tag.color", comment: "Color")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                        ForEach(TagColorPalette.colors, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: colorHex == hex ? 3 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(NSLocalizedString("tag.edit", comment: "Edit Tag"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "Save")) { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = tag.name
                colorHex = tag.colorHex
            }
            .errorAlert($saveError)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tag.name = trimmed
        tag.colorHex = colorHex
        if let failure = modelContext.saveOrError() {
            saveError = failure
            return
        }
        dismiss()
    }
}

/// Sheet that lets the user pick a target tag to merge the source tag into.
struct TagMergeView: View {
    @Environment(\.dismiss) private var dismiss

    let source: Tag
    let tags: [Tag]
    let onMerge: (Tag) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(tags.filter { $0.persistentModelID != source.persistentModelID }) { tag in
                        Button {
                            onMerge(tag)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color(hex: tag.colorHex))
                                    .frame(width: 10, height: 10)
                                Text(tag.name)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(
                        String(
                            format: NSLocalizedString("tag.merge_into", comment: "Merge into"),
                            source.name
                        )
                    )
                }
            }
            .navigationTitle(NSLocalizedString("tag.merge_title", comment: "Merge Tag"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
            }
        }
    }
}
