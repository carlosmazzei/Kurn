//
//  MeetingListSelection.swift
//  Kurn
//
//  Multi-selection on the meetings list: whether the list is in selection
//  mode and which meetings are picked. Selection is by id and survives the
//  list being filtered or searched, but every action resolves it against the
//  meetings currently shown (`selected(from:)`) — deleting or exporting a
//  meeting the user can no longer see would be a surprise.
//

import Foundation

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

    /// The picked meetings among `visible`, in `visible`'s order.
    @MainActor
    func selected(from visible: [Meeting]) -> [Meeting] {
        visible.filter { selectedIDs.contains($0.id) }
    }
}
