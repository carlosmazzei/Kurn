//
//  KurnApp.swift
//  Kurn
//
//  App entry point: builds the SwiftData container for all models and injects
//  shared app settings. Launch screen is provided declaratively (no storyboard).
//

import SwiftData
import SwiftUI

#if canImport(UIKit)
/// Minimal app delegate: SwiftUI has no scene hook for background-URLSession
/// relaunch events, and without answering this callback iOS stops relaunching
/// the app for finished Whisper chunk uploads.
final class KurnAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        WhisperBackgroundUploader.handleEvents(identifier: identifier, completionHandler: completionHandler)
    }
}
#endif

@main
struct KurnApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(KurnAppDelegate.self) private var appDelegate
    #endif
    /// Shared, observable preferences (provider, default mode/language).
    @State private var settings = AppSettings()
    /// Per-session Face ID / passcode gate guarding the recordings UI. Reset
    /// on every background transition so a borrowed-unlocked device cannot
    /// expose meeting audio just by reopening the app.
    @State private var accessGate = RecordingAccessGate()
    /// App-level coordinator that resumes `.pending` transcriptions (runs
    /// interrupted by backgrounding or a process death) whenever the app
    /// becomes active. Separate from the per-screen view models; cross-instance
    /// re-entrancy guards keep them from double-transcribing a recording.
    @State private var transcriptionResumer: TranscriptionViewModel?

    @Environment(\.scenePhase) private var scenePhase

    /// One container for the whole app, persisted on disk.
    let modelContainer: ModelContainer = {
        let schema = Schema([
            Meeting.self,
            Recording.self,
            Transcript.self,
            Speaker.self,
            Summary.self,
            Folder.self,
            Tag.self,
            SmartFolder.self
        ])
        ModelStoreProtection.apply()
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            // On a fresh install the first `apply()` above was a no-op (the
            // store didn't exist yet); SwiftData just created it, so apply
            // again now the file exists. The protection attribute can be set
            // on an already-open file and still takes effect on its next
            // close, so this also hardens the just-created store for later
            // in this same session.
            ModelStoreProtection.apply()
            return container
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        let container = modelContainer
        PhoneSessionController.shared.activate()
        #if canImport(UIKit)
        ResourcePressureMonitor.shared.start()
        #endif
        // Clean up after a process that died mid-recording (orphaned Live
        // Activity + an unsaved audio file with no matching `Recording` row).
        // The snapshot of any orphaned Live Activities is taken synchronously
        // at launch, before any recording UI exists, so a new recording started
        // immediately after launch is never mistaken for an orphan.
        RecordingRecovery.recoverOrphans(modelContainer: container)
        // And after one that died mid-transcription: recordings stuck at
        // `.inProgress` become `.pending` (checkpointed, resumable) or
        // `.failed`, before the first resume pass below runs.
        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)
        #if canImport(BackgroundTasks)
        // BGTaskScheduler requires all handlers registered before the app
        // finishes launching.
        TranscriptionScheduler.register(container: container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environment(settings)
                    .environment(accessGate)
                // Covers meeting/transcript content in the app-switcher
                // snapshot taken while the scene isn't active.
                if scenePhase != .active {
                    PrivacyCoverView()
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Lock the recordings gate whenever the app leaves the
                // foreground so the next time it comes back the user has
                // to authenticate again. Only `.background` triggers this —
                // `.inactive` also fires for transient interruptions (a
                // system alert, Control Center) while a recording's sheet is
                // presented, and locking there would tear down that sheet
                // (MeetingsListView swaps its whole unlocked branch for the
                // locked placeholder), abandoning the in-progress recording.
                if phase == .background {
                    accessGate.lock()
                    #if canImport(BackgroundTasks)
                    // Ask the system for a processing window to advance any
                    // interrupted transcription while we're backgrounded.
                    TranscriptionScheduler.scheduleIfWorkRemains(
                        container: modelContainer, settings: settings
                    )
                    #endif
                }
                // Resume transcriptions interrupted by backgrounding or a
                // process death. `.pending` recordings carry a checkpoint, so
                // each continues from its last completed chunk.
                if phase == .active {
                    // Sweep again on every activation, not just at launch: a
                    // background relaunch while the device was locked can't
                    // read the protected store, leaving recordings stuck at
                    // `.inProgress` that only a later, unlocked pass can fix.
                    // Runs genuinely in flight in this process are excluded.
                    TranscriptionRecovery.sweepStaleTranscriptions(
                        modelContainer: modelContainer,
                        excluding: TranscriptionViewModel.activeTranscriptionIDs
                    )
                    if transcriptionResumer == nil {
                        transcriptionResumer = TranscriptionViewModel(
                            modelContext: modelContainer.mainContext
                        )
                    }
                    transcriptionResumer?.resumePendingTranscriptions(settings: settings)
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
