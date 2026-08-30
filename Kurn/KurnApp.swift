//
//  KurnApp.swift
//  Kurn
//
//  App entry point: builds the SwiftData container for all models and injects
//  shared app settings. Launch screen is provided declaratively (no storyboard).
//

#if canImport(MetricKit)
import MetricKit
#endif
import KurnCore
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
    /// Owns the FluidAudio download state. App-level rather than owned by
    /// Settings: the diarization models can now be offered from a meeting's
    /// transcript, where the fallback to the heuristic engine is visible, and
    /// two controllers each holding their own `isDownloading` would disagree.
    @State private var downloads = ModelDownloadController()
    /// App-wide transcription coordinator, shared by both the foreground
    /// resume pass (below) and every meeting-detail screen (injected via the
    /// environment). One instance means a run started by the resumer is visible
    /// as in-progress — with live phase/progress and a working pause — on the
    /// detail screen, instead of each screen owning a separate view model whose
    /// per-instance progress can't see a run another instance started.
    @State private var transcription: TranscriptionViewModel
    /// App-wide playback-enhancement coordinator. Rendering often outlives a
    /// meeting-detail screen, so keeping this at the app level preserves the
    /// task and its progress when the user navigates back and reopens a meeting.
    @State private var playbackEnhancement: PlaybackEnhancementViewModel
    /// App-wide semantic-index coordinator, shared by the transcription
    /// completion path and the launch/foreground backfill sweep. One instance so
    /// both operate on the same main context.
    @State private var semanticIndex: SemanticIndexCoordinator
    /// App-wide wiki coordinator, shared by the transcription completion path and
    /// the launch/foreground backfill sweep. One instance so both operate on the
    /// same main context.
    @State private var wiki: WikiCoordinator

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
            SmartFolder.self,
            SemanticChunk.self,
            WikiArticle.self,
            GeneratedDocument.self
        ])
        #if DEBUG
        // App Store screenshot automation (fastlane `snapshot` + KurnUITests):
        // an in-memory store pre-populated with mock meetings/transcripts/
        // summaries, never touching the real on-disk store. Compiled out of
        // Release builds entirely, so this can never ship to the App Store.
        if ProcessInfo.processInfo.arguments.contains("UI-Testing-Screenshots") {
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                ScreenshotSeedData.seed(into: container.mainContext)
                return container
            } catch {
                fatalError("Failed to create screenshot ModelContainer: \(error)")
            }
        }
        #endif
        do {
            return try ModelContainerBootstrap.makeStore(schema: schema)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    init() {
        // KurnCore has no `os` dependency (it needs to build on Linux), so it
        // exposes this seam instead of logging directly. Wired once, here,
        // before any transcription can run.
        TranscriptQualityFilter.logHandler = { AppLog.transcription.atInfo.info("\($0, privacy: .public)") }
        // Same shape as above, for the cross-cutting `ReliabilityEvent`
        // vocabulary: `logLine` is content-free by construction, so `.public`
        // is safe here without a redaction pass.
        ReliabilityLog.handler = { event in
            switch event.outcome {
            case .failed:
                AppLog.reliability.atError.error("\(event.logLine, privacy: .public)")
            default:
                AppLog.reliability.atInfo.info("\(event.logLine, privacy: .public)")
            }
        }

        let container = modelContainer
        // Build the shared transcription coordinator on the app's main context
        // so the resume pass and the detail screens are the same instance.
        _transcription = State(
            initialValue: TranscriptionViewModel(modelContext: container.mainContext)
        )
        _playbackEnhancement = State(
            initialValue: PlaybackEnhancementViewModel(modelContext: container.mainContext)
        )
        _semanticIndex = State(
            initialValue: SemanticIndexCoordinator(modelContext: container.mainContext)
        )
        _wiki = State(
            initialValue: WikiCoordinator(modelContext: container.mainContext)
        )
        // Lets `StartRecordingIntent` (Siri/Shortcuts/Control Center/Action
        // Button) create a meeting and queue it for `MeetingsListView` to
        // present, without any View having to hand it a `ModelContext`.
        RecordingLauncher.shared.configure(modelContext: container.mainContext, settings: settings)
        PhoneSessionController.shared.activate()
        #if canImport(UIKit)
        ResourcePressureMonitor.shared.start()
        #endif
        #if canImport(MetricKit)
        // Registered unconditionally (consent is checked at delivery time in
        // DiagnosticsSubscriber.didReceive) so subscription doesn't depend on
        // AppSettings' construction order relative to this init.
        MXMetricManager.shared.add(DiagnosticsSubscriber.shared)
        #endif
        // Clean up after a process that died mid-recording (orphaned Live
        // Activity + an unsaved audio file with no matching `Recording` row).
        // The snapshot of any orphaned Live Activities is taken synchronously
        // at launch, before any recording UI exists, so a new recording started
        // immediately after launch is never mistaken for an orphan.
        // Migrate keychain items to AfterFirstUnlock accessibility so background
        // transcription tasks (WhisperBackgroundUploader, BGProcessingTask resume)
        // can read API keys while the device is locked after the first unlock.
        KeychainManager.shared.migrateToBackgroundAccessible()
        RecordingRecovery.recoverOrphans(modelContainer: container)
        // And after one that died mid-transcription: recordings stuck at
        // known on-device `.inProgress` work becomes `.pending`; cloud or
        // unknown work becomes `.failed` to prevent ambiguous paid replay.
        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)
        #if canImport(BackgroundTasks)
        // BGTaskScheduler requires all handlers registered before the app
        // finishes launching.
        TranscriptionScheduler.register(container: container)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(accessGate)
                .environment(downloads)
                .environment(transcription)
                .environment(playbackEnhancement)
                .environment(semanticIndex)
                .environment(wiki)
                // Both the app-switcher privacy placeholder and the lock screen
                // live in a window above everything this hierarchy presents.
                // They used to be an in-hierarchy `ZStack` branch and a view
                // swap inside `MeetingsListView` respectively, neither of which
                // could cover a presented sheet — and the swap destroyed
                // whatever it replaced.
                .securityCover(
                    gate: accessGate,
                    settings: settings,
                    downloads: downloads,
                    modelContainer: modelContainer
                )
                .onChange(of: scenePhase, initial: true) { _, phase in
                    transcription.appSettings = settings
                    semanticIndex.appSettings = settings
                    wiki.appSettings = settings
                    transcription.semanticIndexCoordinator = semanticIndex
                    transcription.wikiCoordinator = wiki
                    // Lock the recordings gate whenever the app leaves the
                    // foreground so the next time it comes back the user has
                    // to authenticate again. Only `.background` triggers this:
                    // `.inactive` also fires for transient interruptions (a
                    // system alert, Control Center, the biometric prompt
                    // itself), and demanding a fresh Face ID after every one of
                    // those would be its own bug. Content is still not exposed
                    // in the meantime — `.inactive` raises the privacy cover,
                    // which is what the app-switcher snapshot captures.
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
                    // process death. `.pending` recordings carry a checkpoint,
                    // so each continues from its last completed chunk.
                    if phase == .active {
                        // Reattach any orphaned recording (and end stuck Live
                        // Activities) without waiting for the next cold launch.
                        // No-op while a recorder session is live.
                        RecordingRecovery.recoverOrphansOnActivate(modelContainer: modelContainer)
                        // Sweep again on every activation, not just at launch: a
                        // background relaunch while the device was locked can't
                        // read the protected store, leaving recordings stuck at
                        // `.inProgress` that only a later, unlocked pass can fix.
                        // Runs genuinely in flight in this process are excluded.
                        TranscriptionRecovery.sweepStaleTranscriptions(
                            modelContainer: modelContainer,
                            excluding: TranscriptionViewModel.activeTranscriptionIDs
                        )
                        transcription.resumePendingTranscriptions(settings: settings)
                        // Backfill the on-device semantic index for meetings
                        // transcribed before indexing existed (or by an older
                        // embedder). Low-priority, cancellable, and a no-op when
                        // the feature is off or everything is already indexed.
                        Task(priority: .utility) { await semanticIndex.backfill() }
                        // Backfill the LLM-generated wiki for meetings without an
                        // up-to-date article. Opt-in, key-gated, and batch-limited
                        // inside the coordinator, so this is a no-op unless the
                        // user turned the feature on.
                        Task(priority: .utility) { await wiki.backfill() }
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
