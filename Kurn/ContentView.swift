//
//  ContentView.swift
//  Kurn
//
//  Root navigation. On compact width (iPhone, or iPad in a narrow Split View)
//  a single NavigationStack hosts the meetings list and the app's other
//  sections, with the folder/library picker reached through a sheet
//  (`FolderSidebarView`, opened from the toolbar). On regular width (iPad,
//  Mac Catalyst) a NavigationSplitView instead shows that same picker as a
//  persistent sidebar column next to the meetings list: the app is declared
//  universal, and a full-screen sheet wasted the width iPad has. `selection` moved up to this
//  view specifically so the same `Binding<LibrarySelection>` can drive both
//  `FolderSidebarView` (sidebar or sheet) and `MeetingsListView`'s own
//  filtering without a sheet round-trip on regular width. Settings is
//  presented as a sheet either way. The recorder and its minimized mini bar
//  are attached here (`recordingSessionPresenter()`), above both layouts, so
//  a recording stays reachable from every screen. A PDF shared into the app
//  from another one is offered here too (`AttachToMeetingView`), above both
//  layouts, for the user to pick the meeting it belongs to.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(IncomingFileInbox.self) private var incomingFiles
    @State private var selection: LibrarySelection = .allMeetings

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    FolderSidebarView(selection: $selection)
                } detail: {
                    NavigationStack {
                        MeetingsListView(selection: $selection)
                    }
                }
            } else {
                NavigationStack {
                    MeetingsListView(selection: $selection)
                }
            }
        }
        .recordingSessionPresenter()
        .sheet(isPresented: Binding(
            get: { incomingFiles.hasPendingFiles },
            set: { if !$0 { incomingFiles.finish() } }
        )) {
            AttachToMeetingView(files: incomingFiles.pendingFiles) { incomingFiles.finish() }
        }
    }
}

#Preview {
    // `ContentView` renders `MeetingsListView`; only `MeetingDetailView` (reached
    // via navigation) reads the shared `TranscriptionCoordinator` and
    // `SummaryViewModel`, so this preview doesn't inject them.
    @Previewable @State var settings = AppSettings()
    let container = try? ModelContainer(
        for: Meeting.self, Recording.self, Transcript.self, Speaker.self, Summary.self,
        Folder.self, Tag.self, SmartFolder.self, GeneratedDocument.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    if let container {
        ContentView()
            .environment(settings)
            .environment(RecordingAccessGate())
            .environment(IncomingFileInbox())
            .environment(RecordingSessionController(modelContext: container.mainContext, settings: settings))
            .modelContainer(container)
    }
}
