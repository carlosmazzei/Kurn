//
//  ContentView.swift
//  Kurn
//
//  One meetings screen with or without Knowledge: with it, the list's bottom
//  bar reaches Meetings / Knowledge / Ask / Documents and its controls move
//  to the top (`MeetingsListToolbar`). The compact stack / regular-width
//  sidebar is the same either way.
//  Recording presentation, review prompts and incoming-file handling stay
//  above both layouts so navigation cannot orphan an active recording.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.modelContext) private var modelContext
    @Environment(IncomingFileInbox.self) private var incomingFiles
    @State private var selection: LibrarySelection = .allMeetings

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("UI-Testing-KnowledgeNavigationPrototype"),
               ProcessInfo.processInfo.arguments.contains("UI-Testing-KnowledgeFixture"),
               ProcessInfo.processInfo.arguments.contains("UI-Testing-Screenshots") {
                KnowledgeNavigationPrototype()
            } else { appNavigation }
            #else
            appNavigation
            #endif
        }
        .recordingSessionPresenter()
        .reviewPromptPresenter()
        .sheet(isPresented: Binding(
            get: { incomingFiles.hasPendingFiles },
            set: { if !$0 { incomingFiles.finish() } }
        )) {
            AttachToMeetingView(files: incomingFiles.pendingFiles, modelContext: modelContext) {
                incomingFiles.finish()
            }
        }
    }

    private var appNavigation: some View {
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
            .environment(ReviewPromptCoordinator())
            .modelContainer(container)
    }
}
