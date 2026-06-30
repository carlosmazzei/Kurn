//
//  FolderPickerView.swift
//  Kurn
//
//  Sheet that assigns a meeting to a user folder (or back to the Inbox by
//  picking "None"). Driven by the "Move to folder…" context-menu entry in
//  `MeetingsListView`. Mirrors the drill-down navigation in
//  `FolderSidebarView` so subfolders are reachable as targets: the row body
//  assigns the folder and dismisses, the trailing chevron drills into the
//  folder's children.
//

import SwiftData
import SwiftUI

struct FolderPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let meeting: Meeting

    @Query(filter: #Predicate<Folder> { $0.parent == nil }, sort: \Folder.name)
    private var rootFolders: [Folder]

    @State private var path: [Folder] = []

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationDestination(for: Folder.self) { folder in
                    childrenContent(of: folder)
                }
        }
    }

    // MARK: - Levels

    private var rootContent: some View {
        List {
            Section(NSLocalizedString("folder.section.library", comment: "Library")) {
                Button { move(to: nil) } label: {
                    row(
                        systemImage: "tray",
                        tint: Theme.textSecondary,
                        text: NSLocalizedString("folder.inbox", comment: "Inbox"),
                        isSelected: meeting.folder == nil
                    )
                }
                .buttonStyle(.plain)
            }
            if !rootFolders.isEmpty {
                Section(NSLocalizedString("folder.section.folders", comment: "Folders")) {
                    ForEach(rootFolders) { folder in
                        folderRow(folder)
                    }
                }
            }
        }
        .navigationTitle(NSLocalizedString("folder.move_to", comment: "Move to folder"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
            }
        }
    }

    private func childrenContent(of parent: Folder) -> some View {
        List {
            Section(NSLocalizedString("folder.section.library", comment: "Library")) {
                Button { move(to: parent) } label: {
                    row(
                        systemImage: parent.iconName,
                        tint: Color(hex: parent.colorHex),
                        text: NSLocalizedString("folder.select_this", comment: "Select this folder"),
                        isSelected: meeting.folder?.persistentModelID == parent.persistentModelID
                    )
                }
                .buttonStyle(.plain)
            }
            let children = parent.children.sorted(by: { $0.name < $1.name })
            if !children.isEmpty {
                Section(NSLocalizedString("folder.section.subfolders", comment: "Subfolders")) {
                    ForEach(children) { child in
                        folderRow(child)
                    }
                }
            }
        }
        .navigationTitle(parent.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    private func folderRow(_ folder: Folder) -> some View {
        let hasChildren = !folder.children.isEmpty
        return HStack(spacing: 0) {
            Button { move(to: folder) } label: {
                row(
                    systemImage: folder.iconName,
                    tint: Color(hex: folder.colorHex),
                    text: folder.name,
                    isSelected: meeting.folder?.persistentModelID == folder.persistentModelID
                )
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
    }

    private func row(systemImage: String, tint: Color, text: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 26, alignment: .center)
                .foregroundStyle(tint)
            Text(text).foregroundStyle(Theme.textPrimary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func move(to folder: Folder?) {
        meeting.folder = folder
        try? modelContext.save()
        dismiss()
    }
}
