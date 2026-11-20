//
//  MeetingsListToolbar.swift
//  Kurn
//
//  One meetings screen in both layouts. With Knowledge on, the bottom bar
//  holds the four places (Meetings, Knowledge, Ask, Documents) beside the
//  record button, and the list's own controls (Library, Filters, Sort,
//  Select) move up beside Settings, each open in the navigation bar. With
//  Knowledge off, the original placements stay.
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
        if settings.knowledgeEnabled {
            knowledgeBrowsingToolbar
        } else {
            legacyBrowsingToolbar
        }
    }

    /// The original toolbar with its buttons moved: the list's controls share
    /// one glass group at the top, Settings has its own, and the bottom bar
    /// reaches the other places the way it reached Ask and Documents.
    @ToolbarContentBuilder
    private var knowledgeBrowsingToolbar: some ToolbarContent {
        // On iPad-regular width the sidebar column already shows the library.
        if horizontalSizeClass != .regular {
            ToolbarItem(placement: .topBarTrailing) { libraryButton(showsTitle: false) }
        }
        ToolbarItem(placement: .topBarTrailing) { filterButton }
        ToolbarItem(placement: .topBarTrailing) { sortMenu }
        ToolbarItem(placement: .topBarTrailing) { selectButton }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) { settingsButton }

        ToolbarItem(placement: .bottomBar) { destinationButton(.meetings) {} }
        ToolbarItem(placement: .bottomBar) { destinationButton(.knowledge) { showingKnowledge = true } }
        ToolbarItem(placement: .bottomBar) { destinationButton(.ask) { showingAsk = true } }
        ToolbarItem(placement: .bottomBar) { destinationButton(.documents) { showingDocuments = true } }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        // At accessibility text sizes the title would crowd the four places
        // out of the bar; the accessibility label still names the action.
        ToolbarItem(placement: .bottomBar) {
            if dynamicTypeSize.isAccessibilitySize {
                recordButton.labelStyle(.iconOnly)
            } else {
                recordButton.labelStyle(.titleAndIcon)
            }
        }
    }

    /// A place in the bottom bar. Meetings is the screen itself, so it is
    /// marked as the current one by its filled symbol, the accent colour and
    /// the selected trait, never by colour alone.
    private func destinationButton(_ destination: AppRootDestination, action: @escaping () -> Void) -> some View {
        let isCurrent = destination == .meetings
        return Button(action: action) {
            Label(destination.title, systemImage: isCurrent ? destination.systemImage + ".fill" : destination.systemImage)
        }
        .tint(isCurrent ? Theme.accent : nil)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("root.destination.\(destination.rawValue)")
    }

    @ToolbarContentBuilder
    private var legacyBrowsingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { selectButton }
        ToolbarItem(placement: .topBarTrailing) { sortMenu }
        // Splits the shared glass background so sorting and settings read as
        // two separate controls rather than one segmented capsule.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) { settingsButton }

        // On iPad-regular width the same selection is always visible in
        // `FolderSidebarView`'s persistent sidebar column (D6), so this
        // button would just open a sheet duplicating what's already on
        // screen — hidden there rather than left as a redundant control.
        if horizontalSizeClass != .regular {
            ToolbarItem(placement: .bottomBar) { libraryButton(showsTitle: true) }
        }
        ToolbarItem(placement: .bottomBar) { filterButton }
        if settings.semanticSearchEnabled {
            ToolbarItem(placement: .bottomBar) { askButton }
        }
        ToolbarItem(placement: .bottomBar) { documentsButton }
        // Everything above shares one glass capsule; the flexible spacer pushes
        // the record button to the trailing edge *and* gives it its own.
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { recordButton.labelStyle(.titleAndIcon) }
    }

    // MARK: - Primary action

    /// The standalone layout and root navigation share the same recording action.
    var recordButton: some View { RecordingActionButton() }

    // MARK: - Bottom bar

    /// Opens `FolderSidebarView`. The label mirrors the active selection
    /// (built-in bucket icon or folder icon + name) so the user always sees
    /// what they're looking at.
    /// At the top (Knowledge on) only the icon fits beside the other controls;
    /// the accessibility value still names the selection.
    func libraryButton(showsTitle: Bool) -> some View {
        Button { showingSidebar = true } label: {
            Label(selectionTitle, systemImage: selectionSystemImage)
                .labelStyle(LibraryLabelStyle(showsTitle: showsTitle))
        }
        .accessibilityLabel(NSLocalizedString("meetings.bucket", comment: "Library"))
        .accessibilityValue(selectionTitle)
        .accessibilityIdentifier("meetings.library")
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
        .accessibilityValue(filter.isActive ? "\(filter.activeCount)" : "")
        .accessibilityIdentifier("meetings.filters")
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

/// The library button's label: the selection's name beside its icon in the
/// bottom bar, the icon alone at the top.
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
