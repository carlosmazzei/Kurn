//
//  MeetingsListSelectionMode.swift
//  Kurn
//
//  The meetings list's selection mode: a checkmark beside each card, a toolbar
//  that swaps browsing and recording for Select All / Done / Export / Delete,
//  and the bulk delete. Entered from the toolbar's Select button or a card's
//  context menu. Rendering only: what is selected, what an action applies to,
//  the titles and the delete itself all live in `MeetingListSelection`.
//
//  Its own file because `MeetingsListView.swift` is close to the SwiftLint
//  limits; the state it reads is declared non-private over there.
//

import KurnCore
import SwiftUI

extension MeetingsListView {

    /// The selected meetings among those shown, in list order. Actions apply
    /// to these only, never to a selection the current filter hides.
    var selectedMeetings: [Meeting] { listSelection.selected(from: filtered) }

    var listTitle: String { listSelection.navigationTitle(visible: filtered) }

    @ViewBuilder
    func selectableCard(for meeting: Meeting, showsDate: Bool) -> some View {
        let card = MeetingCard(meeting: meeting, showsDate: showsDate)
        if listSelection.isActive {
            let isSelected = listSelection.isSelected(meeting.id)
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Theme.link : Theme.textTertiary)
                    // The row carries `.isSelected` itself.
                    .accessibilityHidden(true)
                card
            }
        } else {
            card
        }
    }

    func deleteSelectedMeetings() {
        pendingBulkDelete = false
        do throws(AppError) {
            try listSelection.deleteSelected(from: filtered, using: MeetingLibrary(context: modelContext))
        } catch {
            saveError = error
        }
    }

    // MARK: - Toolbar

    /// Enters selection mode; sits beside the sort menu.
    var selectButton: some View {
        Button { listSelection.begin() } label: {
            Label(
                NSLocalizedString("meetings.select", comment: "Select"),
                systemImage: "checkmark.circle"
            )
        }
        .disabled(filtered.isEmpty)
        .accessibilityIdentifier("meetings.select")
    }

    @ToolbarContentBuilder
    var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            let visible = filtered.map(\.id)
            Button(listSelection.toggleAllTitle(for: visible)) {
                listSelection.toggleAll(of: visible)
            }
            .disabled(visible.isEmpty)
            .accessibilityIdentifier("meetings.selection.all")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(NSLocalizedString("common.done", comment: "Done")) { listSelection.end() }
                .accessibilityIdentifier("meetings.selection.done")
        }

        // One glass group: Export / Move / Tags on the left, Delete on the
        // right of the flexible spacer.
        ToolbarItem(placement: .bottomBar) { exportSelectionButton }
        ToolbarItem(placement: .bottomBar) { moveSelectionButton }
        ToolbarItem(placement: .bottomBar) { tagSelectionButton }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { deleteSelectionButton }
    }

    private var exportSelectionButton: some View {
        Button { showingBulkExport = true } label: {
            Label(
                NSLocalizedString("meetings.selection.export", comment: "Export"),
                systemImage: "square.and.arrow.up"
            )
        }
        .labelStyle(.iconOnly)
        .disabled(selectedMeetings.isEmpty)
        .accessibilityIdentifier("meetings.selection.export")
    }

    private var moveSelectionButton: some View {
        Button { bulkMoving = true } label: {
            Label(
                NSLocalizedString("folder.move_to", comment: "Move to folder"),
                systemImage: "folder"
            )
        }
        .labelStyle(.iconOnly)
        .disabled(selectedMeetings.isEmpty)
        .accessibilityIdentifier("meetings.selection.move")
    }

    private var tagSelectionButton: some View {
        Button { bulkTagging = true } label: {
            Label(
                NSLocalizedString("meetings.tag.edit", comment: "Edit tags"),
                systemImage: "tag"
            )
        }
        .labelStyle(.iconOnly)
        .disabled(selectedMeetings.isEmpty)
        .accessibilityIdentifier("meetings.selection.tags")
    }

    private var deleteSelectionButton: some View {
        Button(role: .destructive) { pendingBulkDelete = true } label: {
            Label(
                NSLocalizedString("common.delete", comment: "Delete"),
                systemImage: "trash"
            )
        }
        .labelStyle(.iconOnly)
        .tint(Theme.destructive)
        .disabled(selectedMeetings.isEmpty)
        .accessibilityIdentifier("meetings.selection.delete")
    }
}

extension View {
    /// Confirms deleting `count` selected meetings and everything they own.
    func bulkDeleteDialog(
        isPresented: Binding<Bool>,
        count: Int,
        onConfirm: @escaping () -> Void
    ) -> some View {
        kurnDialog(
            isPresented: isPresented,
            iconSystemName: "trash.fill",
            iconTint: Theme.destructive,
            title: String(
                format: NSLocalizedString("meetings.bulk_delete.confirm", comment: "Delete N meetings?"),
                count
            ),
            message: NSLocalizedString("meetings.bulk_delete.message", comment: "Bulk delete explanation"),
            primaryTitle: String(
                format: NSLocalizedString("meetings.bulk_delete.action", comment: "Delete N"),
                count
            ),
            primaryRole: .destructive,
            primaryAction: onConfirm,
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: { isPresented.wrappedValue = false }
        )
    }
}
