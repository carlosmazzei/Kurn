//
//  MeetingsListToolbar.swift
//  Kurn
//
//  The meetings list's native toolbar. Library scope, filters and Ask share one
//  Liquid Glass group at the bottom; a `ToolbarSpacer` splits the record button
//  off into a group of its own, so the primary action reads as separate from the
//  browsing controls instead of being a floating button drawn over a fake bar.
//
//  This lives in its own file because `MeetingsListView.swift` is already close
//  to the SwiftLint file-length limit. The members it reaches for are therefore
//  declared non-private over there.
//

import SwiftData
import SwiftUI

extension MeetingsListView {

    @ToolbarContentBuilder
    var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { sortMenu }
        // Splits the shared glass background so sorting and settings read as
        // two separate controls rather than one segmented capsule.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) { settingsButton }

        ToolbarItem(placement: .bottomBar) { libraryButton }
        ToolbarItem(placement: .bottomBar) { filterButton }
        if settings.semanticSearchEnabled {
            ToolbarItem(placement: .bottomBar) { askButton }
        }
        ToolbarItem(placement: .bottomBar) { documentsButton }
        // Everything above shares one glass capsule; the flexible spacer pushes
        // the record button to the trailing edge *and* gives it its own.
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { recordButton }
    }

    // MARK: - Primary action

    /// The record button, deliberately alone in its glass group and tinted with
    /// the brand accent so it stays the loudest thing on screen.
    var recordButton: some View {
        Button(action: startRecording) {
            Label(
                NSLocalizedString("meetings.record", comment: "Record"),
                systemImage: "record.circle.fill"
            )
        }
        .labelStyle(.titleAndIcon)
        .tint(Theme.accent)
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier("meetings.record")
    }

    /// Create the meeting the recorder will record into, then present it. Errors
    /// surface through `saveError` rather than being dropped.
    func startRecording() {
        let viewModel = MeetingsViewModel(modelContext: modelContext)
        let meeting = viewModel.createMeeting(title: "")
        saveError = viewModel.error
        recordMeeting = meeting
    }

    // MARK: - Bottom bar

    /// Opens `FolderSidebarView`. The label mirrors the active selection
    /// (built-in bucket icon or folder icon + name) so the user always sees
    /// what they're looking at.
    var libraryButton: some View {
        Button { showingSidebar = true } label: {
            Label(selectionTitle, systemImage: selectionSystemImage)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityLabel(NSLocalizedString("meetings.bucket", comment: "Library"))
        .accessibilityValue(selectionTitle)
    }

    /// Opens `FilterBarView`. Shows the active filter count inline so the badge
    /// the old chip carried isn't lost.
    var filterButton: some View {
        Button { showingFilterBar = true } label: {
            if filter.isActive {
                Label("\(filter.activeCount)", systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.titleAndIcon)
            } else {
                Label(
                    NSLocalizedString("filter.title", comment: "Filters"),
                    systemImage: "line.3.horizontal.decrease"
                )
            }
        }
        .tint(filter.isActive ? Theme.accent : nil)
        .accessibilityLabel(NSLocalizedString("filter.title", comment: "Filters"))
    }

    var askButton: some View {
        Button { showingAsk = true } label: {
            Label(
                NSLocalizedString("meetings.ask", comment: "Ask"),
                systemImage: "bubble.left.and.text.bubble.right"
            )
        }
        .accessibilityIdentifier("meetings.ask")
    }

    var documentsButton: some View {
        Button { showingDocuments = true } label: {
            Label(
                NSLocalizedString("documents.title", comment: "Documents"),
                systemImage: "doc.text"
            )
        }
        .accessibilityIdentifier("navigation.documents")
    }

    // MARK: - Navigation bar

    var sortMenu: some View {
        Menu {
            Picker(
                NSLocalizedString("meetings.sort", comment: "Sort"),
                selection: Binding(
                    get: { settings.meetingsSortOrder },
                    set: { settings.meetingsSortOrder = $0 }
                )
            ) {
                ForEach(MeetingsSortOrder.allCases) { order in
                    Label(order.displayName, systemImage: order.systemImage).tag(order)
                }
            }
        } label: {
            Label(
                NSLocalizedString("meetings.sort", comment: "Sort"),
                systemImage: "arrow.up.arrow.down"
            )
        }
        .accessibilityLabel(NSLocalizedString("meetings.sort", comment: "Sort"))
    }

    var settingsButton: some View {
        Button { showingSettings = true } label: {
            Label(
                NSLocalizedString("settings.title", comment: "Settings"),
                systemImage: "gearshape"
            )
        }
        // `ScreenshotUITests.testSettings` taps this by identifier; it moved
        // here from the old hand-rolled bottom bar and must keep the name.
        .accessibilityIdentifier("nav.settings")
    }
}
