//
//  ContentView.swift
//  Kurn
//
//  Root navigation. On compact width (iPhone, or iPad in a narrow Split View)
//  a single NavigationStack hosts the meetings list and the app's other
//  sections, with the folder/library picker reached through a sheet
//  (`FolderSidebarView`, opened from the toolbar). On regular width (iPad,
//  Mac Catalyst) a NavigationSplitView instead shows that same picker as a
//  persistent sidebar column next to the meetings list — the D6 track of
//  docs/design-review-liquid-glass.md: the app is declared universal, but
//  had no iPad-specific navigation before this. `selection` moved up to this
//  view specifically so the same `Binding<LibrarySelection>` can drive both
//  `FolderSidebarView` (sidebar or sheet) and `MeetingsListView`'s own
//  filtering without a sheet round-trip on regular width. Settings is
//  presented as a sheet either way.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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
        .onOpenURL { url in
            RecordingCommandRouter.shared.handle(url)
        }
    }
}

#Preview {
    // `ContentView` renders `MeetingsListView`; only `MeetingDetailView` (reached
    // via navigation) reads the shared `TranscriptionViewModel`, so this preview
    // doesn't inject one.
    ContentView()
        .environment(AppSettings())
        .environment(RecordingAccessGate())
        .modelContainer(for: [
            Meeting.self, Recording.self, Transcript.self, Speaker.self, Summary.self,
            Folder.self, Tag.self, SmartFolder.self, GeneratedDocument.self
        ], inMemory: true)
}
