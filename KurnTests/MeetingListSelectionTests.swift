//
//  MeetingListSelectionTests.swift
//  KurnTests
//
//  Selection mode on the meetings list: entering and leaving it, toggling,
//  select/deselect all over what is shown, and resolving the selection
//  against the visible meetings only.
//

import Foundation
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
}
