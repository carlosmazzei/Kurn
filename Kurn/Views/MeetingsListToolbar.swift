//
//  MeetingsListToolbar.swift
//  Kurn
//
//  In the four-destination root, Library / Filters / Sort / Select share the
//  upper options menu; Settings and Record remain direct upper actions. No
//  bottom toolbar competes with the root tab bar. The feature-off layout keeps
//  the existing standalone toolbar placements.
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
        if usesRootTabs {
            rootBrowsingToolbar
        } else {
            legacyBrowsingToolbar
        }
    }

    @ToolbarContentBuilder
    private var rootBrowsingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                libraryButton
                filterButton
                sortMenu
                selectButton
            } label: {
                Label(NSLocalizedString("meetings.options", comment: "List options"), systemImage: "ellipsis.circle")
            }
            .accessibilityValue(selectionTitle)
            .accessibilityIdentifier("meetings.options")
        }
        ToolbarItem(placement: .topBarTrailing) { settingsButton }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) { recordButton.labelStyle(.iconOnly) }
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
            ToolbarItem(placement: .bottomBar) { libraryButton }
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

    /// The record button, deliberately alone in its glass group and tinted with
    /// the brand accent so it stays the loudest thing on screen. While a
    /// recording runs minimized it says so and re-opens it, rather than
    /// reading "Record" over an action that cannot start a second capture.
    var recordButton: some View {
        Button(action: startRecording) {
            if recordingSession.isActive {
                Label(
                    recordingSession.isPaused
                        ? NSLocalizedString("recorder.mini.paused", comment: "Mini recorder bar: paused")
                        : NSLocalizedString("recorder.mini.recording", comment: "Mini recorder bar: recording"),
                    systemImage: recordingSession.isPaused ? "pause.circle.fill" : "waveform"
                )
            } else {
                Label(
                    NSLocalizedString("meetings.record", comment: "Record"),
                    systemImage: "record.circle.fill"
                )
            }
        }
        .tint(Theme.accent)
        .buttonStyle(.glassProminent)
        .accessibilityHint(recordingSession.isActive
            ? NSLocalizedString("recorder.mini.hint", comment: "Opens the full recorder")
            : "")
        .accessibilityIdentifier("meetings.record")
    }

    /// Create the meeting the recorder will record into, then start the
    /// session. While a recording is already running (minimized to the mini
    /// bar) the button re-opens it instead of creating a second meeting. A
    /// failed save surfaces through `saveError` and opens no recorder, since
    /// there would be no committed meeting to record into.
    func startRecording() {
        guard !recordingSession.isActive else {
            recordingSession.expand()
            return
        }
        do throws(AppError) {
            let meeting = try MeetingLibrary(context: modelContext)
                .createMeeting(title: "", language: settings.defaultLanguage)
            recordingSession.begin(meeting: meeting)
        } catch {
            saveError = error
        }
    }

    // MARK: - Bottom bar

    /// Opens `FolderSidebarView`. The label mirrors the active selection
    /// (built-in bucket icon or folder icon + name) so the user always sees
    /// what they're looking at.
    var libraryButton: some View {
        Button { showingSidebar = true } label: {
            Label(usesRootTabs ? NSLocalizedString("meetings.bucket", comment: "Library") : selectionTitle, systemImage: selectionSystemImage)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityLabel(NSLocalizedString("meetings.bucket", comment: "Library"))
        .accessibilityValue(selectionTitle)
        .accessibilityIdentifier("meetings.library")
    }

    /// Opens `FilterBarView`. Shows the active filter count inline so the badge
    /// the old chip carried isn't lost.
    var filterButton: some View {
        Button { showingFilterBar = true } label: {
            if filter.isActive {
                Label(usesRootTabs ? "\(NSLocalizedString("filter.title", comment: "Filters")) (\(filter.activeCount))" : "\(filter.activeCount)",
                    systemImage: "line.3.horizontal.decrease")
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
