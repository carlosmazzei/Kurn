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
    /// Per-session Face ID / passcode gate guarding the recordings UI. Reset
    /// on every background transition so a borrowed-unlocked device cannot
    /// expose meeting audio just by reopening the app.
    @State private var accessGate = RecordingAccessGate()

    @Environment(\.scenePhase) private var scenePhase

    /// One container for the whole app, persisted on disk.
    let modelContainer: ModelContainer = {
        let schema = Schema([
            Meeting.self,
            Recording.self,
            Transcript.self,
            Speaker.self,
            Summary.self,
            Folder.self
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
        #if canImport(UIKit)
        ResourcePressureMonitor.shared.start()
        #endif
        // Clean up after a process that died mid-recording (orphaned Live
        // Activity + an unsaved audio file with no matching `Recording` row).
        RecordingRecovery.recoverOrphans(modelContainer: modelContainer)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(accessGate)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Lock the recordings gate whenever the app leaves the
                    // foreground so the next time it comes back the user has
                    // to authenticate again.
                    if phase == .background {
                        accessGate.lock()
                    }
                    // Pre-warm the FluidAudio ASR model while the app is in the
                    // foreground. The one-time CoreML/ANE compilation costs tens
                    // of seconds and fails outright if first attempted from the
                    // background ("could not communicate with a helper
                    // application"), so doing it here — gated to users who've
                    // selected and consented to the on-device engine — keeps
                    // later transcriptions fast and reliable.
                    guard phase == .active, settings.usesFluidAudioModel else { return }
                    prewarmFluidAudioModel()
                }
        }
        .modelContainer(modelContainer)
    }

    private func prewarmFluidAudioModel() {
        #if canImport(FluidAudio)
        Task.detached(priority: .utility) {
            await FluidAudioModelStore.shared.prewarm()
        }
        #endif
    }
}
