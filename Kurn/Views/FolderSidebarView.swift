//
//  FolderSidebarView.swift
//  Kurn
//
//  Sheet-presented drawer that drives the `LibrarySelection` shown by
//  `MeetingsListView`. The root level lists every built-in bucket
//  (All / Inbox / Favorites / Archive) and the user's root folders; tapping a
//  folder's row body selects it and closes the sheet, while tapping the
//  trailing chevron drills into its subfolders (with breadcrumb via the
//  enclosing NavigationStack). "+ New" always creates a folder at the level
//  the user is currently looking at. Deletion uses `.nullify`, so meetings
//  only move back to the Inbox — their audio, transcripts and summaries are
//  preserved.
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

    /// Chain of folders the user has drilled into, oldest first. Driven by
    /// `NavigationStack(path:)` so the system back gesture / button restores
    /// state automatically.
    @State private var path: [Folder] = []
    /// Set by the "+ New" button. Wraps the parent context (root or current
    /// drill-down folder) so the form knows where to insert the new folder.
    @State private var creating: NewFolderContext?
    @State private var editing: Folder?
    @State private var pendingDelete: Folder?

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationDestination(for: Folder.self) { folder in
                    childrenContent(of: folder)
                }
        }
        .sheet(item: $creating) { ctx in
            FolderFormView(mode: .create(parent: ctx.parent))
        }
        .sheet(item: $editing) { folder in
            FolderFormView(mode: .edit(folder))
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

    // MARK: - Root level

    private var rootContent: some View {
        List {
            Section(NSLocalizedString("folder.section.library", comment: "Library")) {
                ForEach(MeetingsLibraryBucket.allCases) { bucket in
                    bucketRow(bucket)
                }
            }
            folderSection(folders: rootFolders, parent: nil)
        }
        .navigationTitle(NSLocalizedString("meetings.bucket", comment: "Library"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
            }
        }
    }

    // MARK: - Drilled-in level

    private func childrenContent(of parent: Folder) -> some View {
        List {
            folderSection(folders: parent.children.sorted(by: { $0.createdAt < $1.createdAt }),
                          parent: parent)
        }
        .navigationTitle(parent.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    selection = .folder(parent.persistentModelID)
                    dismiss()
                } label: {
                    Label(
                        NSLocalizedString("folder.select_this", comment: "Select this folder"),
                        systemImage: "checkmark.circle"
                    )
                }
                .accessibilityLabel(NSLocalizedString("folder.select_this", comment: "Select this folder"))
            }
        }
    }

    // MARK: - Reusable folder section

    @ViewBuilder
    private func folderSection(folders: [Folder], parent: Folder?) -> some View {
        Section {
            if folders.isEmpty {
                Text(NSLocalizedString("folder.empty", comment: "No folders yet"))
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(folders) { folder in
                    folderRow(folder)
                }
            }
        } header: {
            HStack {
                Text(parent == nil
                     ? NSLocalizedString("folder.section.folders", comment: "Folders")
                     : NSLocalizedString("folder.section.subfolders", comment: "Subfolders"))
                Spacer()
                Button {
                    creating = NewFolderContext(parent: parent)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityLabel(NSLocalizedString("folder.new", comment: "New folder"))
            }
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
        let hasChildren = !folder.children.isEmpty
        return HStack(spacing: 0) {
            Button {
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

            if hasChildren {
                Button { path.append(folder) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("folder.open_subfolders", comment: "Open subfolders"))
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = folder
            } label: {
                Label(NSLocalizedString("folder.delete", comment: "Delete"), systemImage: "trash")
            }
            Button {
                editing = folder
            } label: {
                Label(NSLocalizedString("folder.rename", comment: "Edit"), systemImage: "pencil")
            }
            .tint(Theme.info)
        }
    }

    // MARK: - Mutations

    private func deleteFolder(_ folder: Folder) {
        // Relationship rule is .nullify on both sides, so SwiftData detaches
        // child meetings and subfolders automatically.
        if selection == .folder(folder.persistentModelID) {
            selection = .bucket(.all)
        }
        // If the user is currently drilled into this folder, pop back so the
        // navigation stack does not point at a deleted model.
        path.removeAll { $0.persistentModelID == folder.persistentModelID }
        modelContext.delete(folder)
        try? modelContext.save()
    }
}

/// Wrapper used to identify the parent context for a folder being created so
/// `sheet(item:)` can drive the create flow with a single state variable for
/// both root and subfolder cases.
private struct NewFolderContext: Identifiable {
    let id = UUID()
    let parent: Folder?
}
