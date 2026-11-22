//
//  FolderPickerView.swift
//  Kurn
//
//  Sheet that assigns meetings to a user folder (or back to the Inbox by
//  picking "None"). Driven by the "Move to folder…" context-menu entry in
//  `MeetingsListView` and by the selection-mode Move button, which passes
//  every selected meeting. A row's checkmark means every selected meeting
//  already sits in that folder. Mirrors the drill-down navigation in
//  `FolderSidebarView` so subfolders are reachable as targets: the row body
//  assigns the folder and dismisses, the trailing chevron drills into the
//  folder's children.
//

import SwiftData
import KurnCore
import SwiftUI

struct FolderPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The meetings the pick applies to; one for the context-menu move,
    /// every selected meeting for the selection-mode Move button.
    let meetings: [Meeting]
    /// Called after a successful move so the caller can leave selection mode.
    var onApplied: (() -> Void)?

    init(meetings: [Meeting], onApplied: (() -> Void)? = nil) {
        self.meetings = meetings
        self.onApplied = onApplied
    }

    /// Convenience for the single-meeting context-menu entry.
    init(meeting: Meeting) {
        self.init(meetings: [meeting])
    }

    /// The shared folder only when ALL selected meetings sit there; a mixed
    /// selection shows no checkmark.
    private func isShared(_ folder: Folder?) -> Bool {
        meetings.allSatisfy { $0.folder?.persistentModelID == folder?.persistentModelID }
    }

    /// The checkmark shows the row currently picked in this sheet (seeded with
    /// the shared folder), not wherever a meeting happens to sit.
    private func selectionMatches(_ folder: Folder?) -> Bool {
        switch selected {
        case .some(let picked):
            return picked?.persistentModelID == folder?.persistentModelID
        case .none:
            return isShared(folder)
        }
    }

    @Query(filter: #Predicate<Folder> { $0.parent == nil }, sort: \Folder.name)
    private var rootFolders: [Folder]

    @State private var path: [Folder] = []
    /// The picked destination; seeded with the shared current folder so the
    /// Move button can be tapped without re-tapping a row.
    @State private var selected: Folder??
    /// Set when moving the meeting fails to save, so the failure surfaces and the
    /// sheet stays open.
    @State private var saveError: AppError?

    var body: some View {
        NavigationStack(path: $path) {
            rootContent
                .navigationDestination(for: Folder.self) { folder in
                    childrenContent(of: folder)
                }
        }
        .errorAlert($saveError)
    }

    // MARK: - Levels

    private var rootContent: some View {
        List {
            Section(NSLocalizedString("folder.section.library", comment: "Library")) {
                Button { selected = .some(nil) } label: {
                    row(
                        systemImage: "tray",
                        tint: Theme.textSecondary,
                        text: NSLocalizedString("folder.none", comment: "No folder"),
                        isSelected: selectionMatches(nil)
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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Text(NSLocalizedString("folder.picker.footer", comment: "One folder per meeting"))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("folder.move", comment: "Move")) {
                    if let selection = selected { move(to: selection) }
                }
                .inkProminent()
                // Requires a deliberate pick: with a mixed selection there is
                // no current folder to default to.
                .disabled(selected == nil)
            }
        }
    }

    private func childrenContent(of parent: Folder) -> some View {
        List {
            Section(NSLocalizedString("folder.section.library", comment: "Library")) {
                Button { selected = parent } label: {
                    row(
                        systemImage: parent.iconName,
                        tint: Color(hex: parent.colorHex),
                        text: NSLocalizedString("folder.select_this", comment: "Select this folder"),
                        isSelected: selectionMatches(parent)
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
            Button { selected = folder } label: {
                row(
                    systemImage: folder.iconName,
                    tint: Color(hex: folder.colorHex),
                    text: folder.name,
                    isSelected: selectionMatches(folder)
                )
            }
            .buttonStyle(.plain)

            if hasChildren {
                Button { path.append(folder) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(.footnote, weight: .semibold))
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
                .accessibilityHidden(true)
            Text(text).foregroundStyle(Theme.textPrimary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.link)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func move(to folder: Folder?) {
        for meeting in meetings { meeting.folder = folder }
        if let failure = modelContext.saveOrError() {
            saveError = failure
            return
        }
        dismiss()
        onApplied?()
    }
}
