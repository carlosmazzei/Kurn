//
//  FolderPickerView.swift
//  Kurn
//
//  Sheet that assigns a meeting to a user folder (or back to the Inbox by
//  picking "None"). Driven by the "Move to folder…" context-menu entry in
//  `MeetingsListView`. Kept separate from `FolderSidebarView` so the picker
//  always closes after one tap regardless of how navigation is structured.
//

import SwiftData
import SwiftUI

struct FolderPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let meeting: Meeting

    @Query(filter: #Predicate<Folder> { $0.parent == nil }, sort: \Folder.name)
    private var rootFolders: [Folder]

    var body: some View {
        NavigationStack {
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
                            Button { move(to: folder) } label: {
                                row(
                                    systemImage: folder.iconName,
                                    tint: Color(hex: folder.colorHex),
                                    text: folder.name,
                                    isSelected: meeting.folder?.persistentModelID == folder.persistentModelID
                                )
                            }
                            .buttonStyle(.plain)
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
