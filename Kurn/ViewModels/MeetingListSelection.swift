//
//  MeetingListSelection.swift
//  Kurn
//
//  Multi-selection on the meetings list: whether the list is in selection
//  mode, which meetings are picked, the titles the selection-mode chrome
//  shows, and the bulk delete. Selection is by id and survives the list being
//  filtered or searched, but every action resolves it against the meetings
//  currently shown (`selected(from:)`) — deleting or exporting a meeting the
//  user can no longer see would be a surprise. `MeetingsListSelectionMode`
//  only renders this.
//

import Foundation
import KurnCore

struct MeetingListSelection: Equatable {
    private(set) var isActive = false
    private(set) var selectedIDs: Set<UUID> = []

    /// Enters selection mode, optionally with one meeting already picked
    /// (the context menu's "Select").
    mutating func begin(with id: UUID? = nil) {
        isActive = true
        selectedIDs = id.map { [$0] } ?? []
    }

    /// Leaves selection mode and forgets the selection.
    mutating func end() {
        isActive = false
        selectedIDs = []
    }

    func isSelected(_ id: UUID) -> Bool { selectedIDs.contains(id) }

    mutating func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// A tap on a card: in selection mode it toggles that meeting and
    /// returns `true`; otherwise it returns `false` and the caller opens it.
    mutating func handleTap(on id: UUID) -> Bool {
        guard isActive else { return false }
        toggle(id)
        return true
    }

    /// Whether every one of `visible` is picked; `false` for an empty list.
    func selectsAll(of visible: [UUID]) -> Bool {
        !visible.isEmpty && visible.allSatisfy(selectedIDs.contains)
    }

    /// "Select All" when something shown is unpicked, otherwise "Deselect
    /// All" — over the shown meetings only.
    mutating func toggleAll(of visible: [UUID]) {
        if selectsAll(of: visible) {
            selectedIDs.subtract(visible)
        } else {
            selectedIDs.formUnion(visible)
        }
    }

    /// The label of the button `toggleAll(of:)` backs.
    func toggleAllTitle(for visible: [UUID]) -> String {
        selectsAll(of: visible)
            ? NSLocalizedString("meetings.selection.deselect_all", comment: "Deselect All")
            : NSLocalizedString("meetings.selection.select_all", comment: "Select All")
    }

    /// The picked meetings among `visible`, in `visible`'s order.
    @MainActor
    func selected(from visible: [Meeting]) -> [Meeting] {
        visible.filter { selectedIDs.contains($0.id) }
    }

    /// "Selected: 3" while selecting, the app name otherwise.
    @MainActor
    func navigationTitle(visible: [Meeting]) -> String {
        guard isActive else { return "Kurn" }
        return String(
            format: NSLocalizedString("meetings.selection.count", comment: "N meetings selected"),
            selected(from: visible).count
        )
    }

    /// Deletes the picked meetings among `visible` in one operation and
    /// leaves selection mode. A failure keeps the selection, so the user can
    /// retry or change it.
    @MainActor
    mutating func deleteSelected(from visible: [Meeting], using library: MeetingLibrary) throws(AppError) {
        try library.deleteMeetings(selected(from: visible))
        end()
    }
}
