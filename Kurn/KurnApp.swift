//
//  KurnApp.swift
//  Kurn
//
//  App entry point: builds the SwiftData container for all models and injects
//  shared app settings. Launch screen is provided declaratively (no storyboard).
//

import SwiftData
import SwiftUI

@main
struct KurnApp: App {
    /// Shared, observable preferences (provider, default mode/language).
    @State private var settings = AppSettings()

    /// One container for the whole app, persisted on disk.
    let modelContainer: ModelContainer = {
        let schema = Schema([
            Meeting.self,
            Recording.self,
            Transcript.self,
            Speaker.self,
            Summary.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        PhoneSessionController.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
        }
        .modelContainer(modelContainer)
    }
}
