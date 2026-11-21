//
//  MeetingsListToolbar.swift
//  Kurn
//
//  One unified meetings screen toolbar regardless of whether Knowledge is on
//  or off. The bottom bar holds the four destinations (Library, Knowledge, Ask,
//  Documents) beside the separate record button; the top trailing bar pairs
//  the list-options menu (Filters, Sort, Select) with Settings.
//
//  This lives in its own file because `MeetingsListView.swift` is already close
//  to the SwiftLint file-length limit. The members it reaches for are therefore
//  declared non-private over there.
//

import KurnCore
import SwiftData
import SwiftUI

extension MeetingsListView {

    @ToolbarContentBuilder
    var listToolbar: some ToolbarContent {
        if listSelection.isActive {
            selectionToolbar
        } else {
            browsingToolbar
        }
    }

    @ToolbarContentBuilder
    var browsingToolbar: some ToolbarContent {
        topTrailingToolbar
        bottomDestinationsToolbar
    }

    /// List options (Filters, Sort, Select) grouped in one menu right beside
    /// Settings so both share one clean trailing chrome group.
    @ToolbarContentBuilder
    private var topTrailingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { listActionsMenu }
        ToolbarItem(placement: .topBarTrailing) { settingsButton }
    }

    /// Four destinations (Library, Knowledge, Ask, Documents) in one group,
    /// separated by a flexible spacer from the standalone Record button.
    @ToolbarContentBuilder
    private var bottomDestinationsToolbar: some ToolbarContent {
        // On iPad-regular width the sidebar column already shows the library.
        if horizontalSizeClass != .regular {
            ToolbarItem(placement: .bottomBar) { libraryButton(showsTitle: false) }
        }
        ToolbarItem(placement: .bottomBar) { destinationButton(.knowledge) { showingKnowledge = true } }
        ToolbarItem(placement: .bottomBar) { destinationButton(.ask) { showingAsk = true } }
        ToolbarItem(placement: .bottomBar) { destinationButton(.documents) { showingDocuments = true } }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        // At accessibility text sizes the title would crowd the destinations
        // out of the bar; the accessibility label still names the action.
        ToolbarItem(placement: .bottomBar) {
            if dynamicTypeSize.isAccessibilitySize {
                recordButton.labelStyle(.iconOnly)
            } else {
                recordButton.labelStyle(.titleAndIcon)
            }
        }
    }

    private func destinationButton(_ destination: AppRootDestination, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(destination.title, systemImage: destination.systemImage)
        }
        .accessibilityIdentifier("root.destination.\(destination.rawValue)")
    }

    // MARK: - Primary action

    /// The standalone layout and root navigation share the same recording action.
    var recordButton: some View { RecordingActionButton() }

    // MARK: - Bottom bar

    /// Opens `FolderSidebarView`. The icon mirrors the active selection
    /// (built-in bucket or folder) and the accessibility value names it.
    func libraryButton(showsTitle: Bool) -> some View {
        Button { showingSidebar = true } label: {
            Label(selectionTitle, systemImage: selectionSystemImage)
                .labelStyle(LibraryLabelStyle(showsTitle: showsTitle))
        }
        .accessibilityLabel(NSLocalizedString("meetings.bucket", comment: "Library"))
        .accessibilityValue(selectionTitle)
        .accessibilityIdentifier("meetings.library")
    }

    // MARK: - Navigation bar

    /// Single overflow menu for Filters, Sort, and Select.
    var listActionsMenu: some View {
        Menu {
            Section {
                filterMenuButton
                selectButton
            }
            Section {
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
            }
        } label: {
            Label(
                NSLocalizedString("meetings.list_actions", comment: "List options"),
                systemImage: filter.isActive ? "ellipsis.circle.fill" : "ellipsis.circle"
            )
        }
        .tint(filter.isActive ? Theme.accent : nil)
        .accessibilityLabel(NSLocalizedString("meetings.list_actions", comment: "List options"))
        .accessibilityValue(filter.isActive ? "\(filter.activeCount)" : "")
        .accessibilityIdentifier("meetings.actions")
    }

    private var filterMenuButton: some View {
        Button { showingFilterBar = true } label: {
            let base = NSLocalizedString("filter.title", comment: "Filters")
            let title = filter.isActive ? "\(base) (\(filter.activeCount))" : base
            Label(title, systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityIdentifier("meetings.filters")
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

/// The library button's label: the selection's name beside its icon when
/// requested, the icon alone in compact destination bars.
private struct LibraryLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            Label(configuration).labelStyle(.titleAndIcon)
        } else {
            Label(configuration).labelStyle(.iconOnly)
        }
    }
}
