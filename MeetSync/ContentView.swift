//
//  ContentView.swift
//  MeetSync
//
//  Root navigation. A single NavigationStack hosts the meetings list, which
//  pushes detail/recorder screens; Settings is presented as a sheet.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            MeetingsListView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .modelContainer(for: [
            Meeting.self, Recording.self, Transcript.self, Speaker.self, Summary.self,
        ], inMemory: true)
}
