//
//  MeetingsListSelectionMode.swift
//  Kurn
//
//  The meetings list's selection mode: a checkmark beside each card, a toolbar
//  that swaps browsing and recording for Select All / Done / Export / Delete,
//  and the bulk delete. Entered from the toolbar's Select button or a card's
//  context menu. The rules — what is selected, what an action applies to —
//  live in `MeetingListSelection`; deletion in `MeetingLibrary`.
//
//  Its own file because `MeetingsListView.swift` is close to the SwiftLint
//  limits; the state it reads is declared non-private over there.
//

import SwiftUI

extension MeetingsListView {

    /// The selected meetings among those shown, in list order. Actions apply
    /// to these only, never to a selection the current filter hides.
    var selectedMeetings: [Meeting] { listSelection.selected(from: filtered) }

    /// "3 selected" while selecting, the app name otherwise.
    var listTitle: String {
        guard listSelection.isActive else { return "Kurn" }
        return String(
            format: NSLocalizedString("meetings.selection.count", comment: "N meetings selected"),
            selectedMeetings.count
        )
    }

    @ViewBuilder
    func selectableCard(for meeting: Meeting) -> some View {
        let card = MeetingCard(meeting: meeting, preview: preview(for: meeting))
        if listSelection.isActive {
            let isSelected = listSelection.isSelected(meeting.id)
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
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
            try MeetingLibrary(context: modelContext).deleteMeetings(selectedMeetings)
            listSelection.end()
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
            Button(listSelection.selectsAll(of: visible)
                ? NSLocalizedString("meetings.selection.deselect_all", comment: "Deselect All")
                : NSLocalizedString("meetings.selection.select_all", comment: "Select All")
            ) {
                listSelection.toggleAll(of: visible)
            }
            .disabled(visible.isEmpty)
            .accessibilityIdentifier("meetings.selection.all")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(NSLocalizedString("common.done", comment: "Done")) { listSelection.end() }
                .accessibilityIdentifier("meetings.selection.done")
        }

        ToolbarItem(placement: .bottomBar) {
            Button { showingBulkExport = true } label: {
                Label(
                    NSLocalizedString("meetings.selection.export", comment: "Export"),
                    systemImage: "square.and.arrow.up"
                )
            }
            .labelStyle(.titleAndIcon)
            .disabled(selectedMeetings.isEmpty)
            .accessibilityIdentifier("meetings.selection.export")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(role: .destructive) { pendingBulkDelete = true } label: {
                Label(
                    NSLocalizedString("common.delete", comment: "Delete"),
                    systemImage: "trash"
                )
            }
            .labelStyle(.titleAndIcon)
            .tint(Theme.accent)
            .disabled(selectedMeetings.isEmpty)
            .accessibilityIdentifier("meetings.selection.delete")
        }
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
            iconTint: Theme.accent,
            title: String(
                format: NSLocalizedString("meetings.bulk_delete.confirm", comment: "Delete N meetings?"),
                count
            ),
            message: NSLocalizedString("meetings.bulk_delete.message", comment: "Bulk delete explanation"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: onConfirm,
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: { isPresented.wrappedValue = false }
        )
    }
}
