//
//  MeetingListSelectionTests.swift
//  KurnTests
//
//  Selection mode on the meetings list: entering and leaving it, toggling,
//  select/deselect all over what is shown, and resolving the selection
//  against the visible meetings only.
//

import Foundation
import KurnCore
import SwiftData
import Testing
@testable import Kurn

@MainActor
struct MeetingListSelectionTests {

    @Test func beginEntersSelectionModeWithAnOptionalFirstPick() {
        var selection = MeetingListSelection()
        #expect(!selection.isActive)

        selection.begin()
        #expect(selection.isActive)
        #expect(selection.selectedIDs.isEmpty)

        let id = UUID()
        selection.begin(with: id)
        #expect(selection.selectedIDs == [id])
    }

    @Test func endLeavesSelectionModeAndForgetsThePicks() {
        var selection = MeetingListSelection()
        selection.begin(with: UUID())
        selection.end()
        #expect(!selection.isActive)
        #expect(selection.selectedIDs.isEmpty)
    }

    @Test func toggleFlipsMembership() {
        var selection = MeetingListSelection()
        let id = UUID()
        selection.toggle(id)
        #expect(selection.isSelected(id))
        selection.toggle(id)
        #expect(!selection.isSelected(id))
    }

    @Test func toggleAllSelectsTheShownMeetingsThenDeselectsThem() {
        var selection = MeetingListSelection()
        let hidden = UUID()
        let shown = [UUID(), UUID()]
        selection.begin(with: hidden)
        #expect(!selection.selectsAll(of: shown))

        selection.toggleAll(of: shown)
        #expect(selection.selectsAll(of: shown))
        #expect(selection.selectedIDs == Set(shown + [hidden]))

        // Deselecting all clears only what is shown.
        selection.toggleAll(of: shown)
        #expect(selection.selectedIDs == [hidden])
    }

    @Test func anEmptyListIsNeverAllSelected() {
        #expect(!MeetingListSelection().selectsAll(of: []))
    }

    @Test func selectedResolvesAgainstTheVisibleMeetingsInTheirOrder() {
        let container = TestModelContainer.make()
        let context = container.mainContext
        context.autosaveEnabled = false
        let first = Meeting(title: "First")
        let second = Meeting(title: "Second")
        let filteredOut = Meeting(title: "Filtered out")
        for meeting in [first, second, filteredOut] { context.insert(meeting) }

        var selection = MeetingListSelection()
        selection.begin(with: filteredOut.id)
        selection.toggle(second.id)
        selection.toggle(first.id)

        #expect(selection.selected(from: [first, second]).map(\.id) == [first.id, second.id])
    }

    @Test func aTapTogglesOnlyInSelectionMode() {
        var selection = MeetingListSelection()
        let id = UUID()
        #expect(!selection.handleTap(on: id))
        #expect(!selection.isSelected(id))

        selection.begin()
        #expect(selection.handleTap(on: id))
        #expect(selection.isSelected(id))
    }

    @Test func toggleAllTitleFollowsWhetherEverythingShownIsPicked() {
        var selection = MeetingListSelection()
        let shown = [UUID()]
        let selectAll = NSLocalizedString("meetings.selection.select_all", comment: "")
        let deselectAll = NSLocalizedString("meetings.selection.deselect_all", comment: "")
        #expect(selection.toggleAllTitle(for: shown) == selectAll)
        selection.toggleAll(of: shown)
        #expect(selection.toggleAllTitle(for: shown) == deselectAll)
    }

    @Test func navigationTitleCountsTheShownSelection() {
        let container = TestModelContainer.make()
        let context = container.mainContext
        context.autosaveEnabled = false
        let shown = Meeting(title: "Shown")
        let hidden = Meeting(title: "Hidden")
        for meeting in [shown, hidden] { context.insert(meeting) }

        var selection = MeetingListSelection()
        #expect(selection.navigationTitle(visible: [shown]) == "Kurn")

        selection.begin(with: shown.id)
        selection.toggle(hidden.id)
        let expected = String(format: NSLocalizedString("meetings.selection.count", comment: ""), 1)
        #expect(selection.navigationTitle(visible: [shown]) == expected)
    }

    @Test func deleteSelectedDeletesTheShownPicksAndEndsSelection() throws {
        let context = ModelContext(TestModelContainer.make())
        let library = MeetingLibrary(context: context)
        let picked = try library.createMeeting(title: "Picked")
        let hidden = try library.createMeeting(title: "Hidden")
        let kept = try library.createMeeting(title: "Kept")

        var selection = MeetingListSelection()
        selection.begin(with: picked.id)
        selection.toggle(hidden.id)
        try selection.deleteSelected(from: [picked, kept], using: library)

        #expect(!selection.isActive)
        let remaining = Set(try context.fetch(FetchDescriptor<Meeting>()).map(\.id))
        #expect(remaining == [hidden.id, kept.id])
    }

    @Test func aFailedDeleteKeepsTheSelection() throws {
        let context = ModelContext(TestModelContainer.make())
        let meeting = try MeetingLibrary(context: context).createMeeting(title: "Picked")
        let failing = MeetingLibrary(context: context, persist: { _ in .persistenceFailed("disk") })

        var selection = MeetingListSelection()
        selection.begin(with: meeting.id)
        // Not `#expect(throws:)`: its closure cannot call a mutating method
        // on the captured selection.
        var failed = false
        do {
            try selection.deleteSelected(from: [meeting], using: failing)
        } catch {
            failed = true
        }
        #expect(failed)
        #expect(selection.isActive)
        #expect(selection.isSelected(meeting.id))
    }
}
