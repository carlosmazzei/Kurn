//
//  FolderSidebarView.swift
//  Kurn
//
//  Sheet-presented drawer that drives the `LibrarySelection` shown by
//  `MeetingsListView`. Lists every built-in bucket (All / Inbox / Favorites /
//  Archive) with its count, then the user's root folders (subfolders are
//  hidden until a follow-up adds breadcrumb navigation). Includes inline
//  create / rename / delete; delete is `.nullify`, so meetings only move back
//  to the Inbox — their audio, transcripts and summaries are preserved.
//

import SwiftData
import SwiftUI

struct FolderSidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Binding var selection: LibrarySelection

    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @Query(filter: #Predicate<Folder> { $0.parent == nil }, sort: \Folder.createdAt)
    private var rootFolders: [Folder]

    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @State private var renaming: Folder?
    @State private var renameText = ""
    @State private var pendingDelete: Folder?

    var body: some View {
        NavigationStack {
            List {
                Section(NSLocalizedString("folder.section.library", comment: "Library")) {
                    ForEach(MeetingsLibraryBucket.allCases) { bucket in
                        bucketRow(bucket)
                    }
                }
                Section {
                    if rootFolders.isEmpty {
                        Text(NSLocalizedString("folder.empty", comment: "No folders yet"))
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    } else {
                        ForEach(rootFolders) { folder in
                            folderRow(folder)
                        }
                    }
                } header: {
                    HStack {
                        Text(NSLocalizedString("folder.section.folders", comment: "Folders"))
                        Spacer()
                        Button {
                            newFolderName = ""
                            creatingFolder = true
                        } label: {
                            Label(
                                NSLocalizedString("folder.new", comment: "New folder"),
                                systemImage: "plus.circle.fill"
                            )
                            .labelStyle(.iconOnly)
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(Theme.accent)
                        }
                        .accessibilityLabel(NSLocalizedString("folder.new", comment: "New folder"))
                    }
                }
            }
            .navigationTitle(NSLocalizedString("meetings.bucket", comment: "Library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
            .alert(
                NSLocalizedString("folder.new", comment: "New folder"),
                isPresented: $creatingFolder
            ) {
                TextField(
                    NSLocalizedString("folder.name_placeholder", comment: "Folder name"),
                    text: $newFolderName
                )
                Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
                Button(NSLocalizedString("common.save", comment: "Save")) {
                    createFolder()
                }
            }
            .alert(
                NSLocalizedString("folder.rename", comment: "Rename folder"),
                isPresented: Binding(
                    get: { renaming != nil },
                    set: { if !$0 { renaming = nil } }
                )
            ) {
                TextField(
                    NSLocalizedString("folder.name_placeholder", comment: "Folder name"),
                    text: $renameText
                )
                Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {
                    renaming = nil
                }
                Button(NSLocalizedString("common.save", comment: "Save")) {
                    commitRename()
                }
            }
            .kurnDialog(
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                iconSystemName: "archivebox.fill",
                iconTint: Theme.warning,
                title: NSLocalizedString("folder.delete.confirm", comment: "Delete folder?"),
                message: NSLocalizedString("folder.delete.message", comment: "Meetings go to Inbox"),
                primaryTitle: NSLocalizedString("folder.delete", comment: "Delete"),
                primaryRole: .destructive,
                primaryAction: {
                    if let folder = pendingDelete { deleteFolder(folder) }
                    pendingDelete = nil
                },
                secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
                secondaryAction: { pendingDelete = nil }
            )
        }
    }

    // MARK: - Rows

    private func bucketRow(_ bucket: MeetingsLibraryBucket) -> some View {
        let isSelected = selection == .bucket(bucket)
        let count = meetings.lazy.filter { bucket.contains($0) }.count
        return Button {
            selection = .bucket(bucket)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: bucket.systemImage)
                    .frame(width: 26, alignment: .center)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                Text(bucket.displayName)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(count)")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func folderRow(_ folder: Folder) -> some View {
        let isSelected = selection == .folder(folder.persistentModelID)
        let count = folder.meetings.count
        return Button {
            selection = .folder(folder.persistentModelID)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: folder.iconName)
                    .frame(width: 26, alignment: .center)
                    .foregroundStyle(Color(hex: folder.colorHex))
                Text(folder.name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(count)")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
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
                pendingDelete = folder
            } label: {
                Label(NSLocalizedString("folder.delete", comment: "Delete"), systemImage: "trash")
            }
            Button {
                renameText = folder.name
                renaming = folder
            } label: {
                Label(NSLocalizedString("folder.rename", comment: "Rename"), systemImage: "pencil")
            }
            .tint(Theme.info)
        }
    }

    // MARK: - Mutations

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folder = Folder(name: trimmed)
        modelContext.insert(folder)
        try? modelContext.save()
    }

    private func commitRename() {
        guard let folder = renaming else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            folder.name = trimmed
            try? modelContext.save()
        }
        renaming = nil
    }

    private func deleteFolder(_ folder: Folder) {
        // The relationship rule is .nullify on both sides, so SwiftData detaches
        // child meetings and subfolders automatically. Nothing else to do.
        if selection == .folder(folder.persistentModelID) {
            selection = .bucket(.all)
        }
        modelContext.delete(folder)
        try? modelContext.save()
    }
}
