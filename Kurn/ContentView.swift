//
//  ContentView.swift
//  Kurn
//
//  Root navigation. A single NavigationStack hosts the meetings list, which
//  pushes detail/recorder screens; Settings is presented as a sheet.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            MeetingsListView()
        }
        .onOpenURL { url in
            RecordingCommandRouter.shared.handle(url)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .environment(RecordingAccessGate())
        .modelContainer(for: [
            Meeting.self, Recording.self, Transcript.self, Speaker.self, Summary.self,
            Folder.self, Tag.self, SmartFolder.self
        ], inMemory: true)
}
