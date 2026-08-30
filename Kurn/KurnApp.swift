//
//  KurnApp.swift
//  Kurn
//
//  App entry point. Registers background callbacks and hands the store to
//  `ModelStoreBootCoordinator`, which walks the H2 boot state machine
//  (docs/resilience-megaplan.md: `waitingForProtectedData` -> `opening` ->
//  `ready`/`recoveryRequired`) instead of the old inline `fatalError` on
//  construction failure. On the common path — protected data available, store
//  opens cleanly — `beginBoot()` resolves to `.ready` synchronously inside
//  `init()`, before `body` is ever evaluated, so behavior is identical to
//  before this file existed. The two states this PR actually targets —
//  `waitingForProtectedData` (a background-only launch while the device is
//  locked) and `recoveryRequired` (a genuine open failure) — render a
//  minimal, store-independent shell instead (`ModelStoreBootViews.swift`) and
//  retry on every foreground activation.
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

/// The app-wide state that only exists once the store has opened — every
/// coordinator `ContentView` and its descendants reach through the
/// environment. Built exactly once, the first time boot reaches `.ready`,
/// whether that happens synchronously in `init()` (the common case) or later,
/// from the foreground-activation retry.
@MainActor
private struct AppEnvironment {
    let modelContainer: ModelContainer
    let transcription: TranscriptionViewModel
    let playbackEnhancement: PlaybackEnhancementViewModel
    let semanticIndex: SemanticIndexCoordinator
    let wiki: WikiCoordinator
}

@main
struct KurnApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(KurnAppDelegate.self) private var appDelegate
    #endif
    /// Shared, observable preferences (provider, default mode/language).
    /// Store-independent, so it exists regardless of boot state.
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
    /// The H2 boot state machine. Its default value (below) already resolves
    /// any DEBUG-only synthetic-failure launch arguments before `init()`'s
    /// body runs, exactly like `settings`/`accessGate`/`downloads` above.
    @State private var boot = KurnApp.makeBootCoordinator()
    /// `nil` until boot reaches `.ready`; every store-dependent coordinator
    /// lives here instead of as separate top-level `@State` properties, since
    /// none of them can exist before a container does.
    @State private var appEnvironment: AppEnvironment?

    @Environment(\.scenePhase) private var scenePhase

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
        _ = NetworkPathObserver.shared

        #if canImport(BackgroundTasks)
        // Registered before the app finishes launching, and — per the H2 boot
        // state machine — before the store has even been opened: the launch
        // handler only reads `bootCoordinator.container` when a task actually
        // fires, never at registration time, so a background-only launch that
        // never gets past `.waitingForProtectedData` still registers cleanly.
        let bootCoordinator = boot
        TranscriptionScheduler.register(containerProvider: { [bootCoordinator] in bootCoordinator.container })
        #endif

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
        // Migrate keychain items to AfterFirstUnlock accessibility so background
        // transcription tasks (WhisperBackgroundUploader, BGProcessingTask resume)
        // can read API keys while the device is locked after the first unlock.
        KeychainManager.shared.migrateToBackgroundAccessible()

        boot.beginBoot()
        if boot.state == .ready, let container = boot.container {
            _appEnvironment = State(initialValue: KurnApp.makeAppEnvironment(container: container, settings: settings))
        } else {
            _appEnvironment = State(initialValue: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            content
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // A background-only launch while locked, or a launch that
                    // failed to open, gets one retry attempt per activation —
                    // this is what lets an app that started in
                    // `.waitingForProtectedData`/`.recoveryRequired` recover
                    // once the device unlocks or the user taps Retry, without
                    // waiting for a fresh cold launch.
                    if appEnvironment == nil {
                        boot.retryIfNeeded()
                        if boot.state == .ready, let container = boot.container {
                            appEnvironment = KurnApp.makeAppEnvironment(container: container, settings: settings)
                        }
                    }
                    guard let appEnvironment else { return }
                    handleScenePhaseChange(phase, environment: appEnvironment)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let appEnvironment {
            ContentView()
                .environment(settings)
                .environment(accessGate)
                .environment(downloads)
                .environment(appEnvironment.transcription)
                .environment(appEnvironment.playbackEnhancement)
                .environment(appEnvironment.semanticIndex)
                .environment(appEnvironment.wiki)
                // Both the app-switcher privacy placeholder and the lock screen
                // live in a window above everything this hierarchy presents.
                // They used to be an in-hierarchy `ZStack` branch and a view
                // swap inside `MeetingsListView` respectively, neither of which
                // could cover a presented sheet — and the swap destroyed
                // whatever it replaced. Neither is needed before `.ready`:
                // there is no meeting content to protect yet.
                .securityCover(
                    gate: accessGate,
                    settings: settings,
                    downloads: downloads,
                    modelContainer: appEnvironment.modelContainer
                )
                .modelContainer(appEnvironment.modelContainer)
        } else if case .recoveryRequired(let failure) = boot.state {
            ModelStoreRecoveryView(failure: failure) { boot.retryIfNeeded() }
        } else {
            // `.waitingForProtectedData`, `.opening`, or (transiently, on the
            // deferred path only) `.ready` with `appEnvironment` not yet
            // built. Never visible on the common synchronous-success launch.
            ModelStoreLaunchProgressView()
        }
    }

    /// Exactly the scene-phase logic this file always had, now reading the
    /// store-dependent coordinators from `environment` instead of bare
    /// top-level properties.
    private func handleScenePhaseChange(_ phase: ScenePhase, environment: AppEnvironment) {
        environment.transcription.appSettings = settings
        environment.semanticIndex.appSettings = settings
        environment.wiki.appSettings = settings
        environment.transcription.semanticIndexCoordinator = environment.semanticIndex
        environment.transcription.wikiCoordinator = environment.wiki
        // Lock the recordings gate whenever the app leaves the foreground so
        // the next time it comes back the user has to authenticate again.
        // Only `.background` triggers this: `.inactive` also fires for
        // transient interruptions (a system alert, Control Center, the
        // biometric prompt itself), and demanding a fresh Face ID after every
        // one of those would be its own bug. Content is still not exposed in
        // the meantime — `.inactive` raises the privacy cover, which is what
        // the app-switcher snapshot captures.
        if phase == .background {
            accessGate.lock()
            #if canImport(BackgroundTasks)
            // Ask the system for a processing window to advance any
            // interrupted transcription while we're backgrounded.
            TranscriptionScheduler.scheduleIfWorkRemains(
                container: environment.modelContainer, settings: settings
            )
            #endif
        }
        // Resume transcriptions interrupted by backgrounding or a process
        // death. `.pending` recordings carry a checkpoint, so each continues
        // from its last completed chunk.
        if phase == .active {
            // Reattach any orphaned recording (and end stuck Live
            // Activities) without waiting for the next cold launch. No-op
            // while a recorder session is live.
            RecordingRecovery.recoverOrphansOnActivate(modelContainer: environment.modelContainer)
            // Sweep again on every activation, not just at launch: a
            // background relaunch while the device was locked can't read the
            // protected store, leaving recordings stuck at `.inProgress`
            // that only a later, unlocked pass can fix. Runs genuinely in
            // flight in this process are excluded.
            TranscriptionRecovery.sweepStaleTranscriptions(
                modelContainer: environment.modelContainer,
                excluding: TranscriptionViewModel.activeTranscriptionIDs
            )
            environment.transcription.resumePendingTranscriptions(settings: settings)
            // Backfill the on-device semantic index for meetings transcribed
            // before indexing existed (or by an older embedder). Low-priority,
            // cancellable, and a no-op when the feature is off or everything
            // is already indexed.
            Task(priority: .utility) { await environment.semanticIndex.backfill() }
            // Backfill the LLM-generated wiki for meetings without an
            // up-to-date article. Opt-in, key/circuit-gated, and
            // batch-limited inside the coordinator, so this is a no-op
            // unless the user turned the feature on.
            Task(priority: .utility) { await environment.wiki.backfill() }
        }
        // Pre-warm the FluidAudio ASR model while the app is in the
        // foreground. The one-time CoreML/ANE compilation costs tens of
        // seconds and fails outright if first attempted from the background
        // ("could not communicate with a helper application"), so doing it
        // here — gated to users who've selected and consented to the
        // on-device engine — keeps later transcriptions fast and reliable.
        guard phase == .active, settings.usesFluidAudioModel else { return }
        prewarmFluidAudioModel(policy: settings.largeTransferPolicy)
    }

    private func prewarmFluidAudioModel(policy: LargeTransferPolicy) {
        #if canImport(FluidAudio)
        Task.detached(priority: .utility) {
            do {
                try ModelDownloadConsent.validateNetworkIfDownloadNeeded(
                    for: [.onDeviceASR],
                    policy: policy
                )
            } catch {
                return
            }
            await FluidAudioModelStore.shared.prewarm()
        }
        #endif
    }

    // MARK: - Boot

    private static func makeBootCoordinator() -> ModelStoreBootCoordinator {
        #if DEBUG
        // UI-test-only: forces `.waitingForProtectedData` so
        // `KurnUITests` can exercise the locked-background-launch shell
        // without a real locked device. Compiled out of Release entirely,
        // matching the existing "UI-Testing-Screenshots" seam below.
        if ProcessInfo.processInfo.arguments.contains("UI-Testing-StoreWaitingForProtectedData") {
            return ModelStoreBootCoordinator(makeStore: KurnApp.makeStore, isProtectedDataAvailable: { false })
        }
        #endif
        return ModelStoreBootCoordinator(makeStore: KurnApp.makeStore)
    }

    @MainActor
    private static func makeStore() throws -> ModelContainer {
        #if DEBUG
        // App Store screenshot automation (fastlane `snapshot` + KurnUITests):
        // an in-memory store pre-populated with mock meetings/transcripts/
        // summaries, never touching the real on-disk store. Compiled out of
        // Release builds entirely, so this can never ship to the App Store.
        if ProcessInfo.processInfo.arguments.contains("UI-Testing-Screenshots") {
            let configuration = ModelConfiguration(schema: KurnModelGraph.schema, isStoredInMemoryOnly: true)
            let container = try ModelContainer(
                for: KurnModelGraph.schema,
                migrationPlan: KurnModelGraph.migrationPlan,
                configurations: [configuration]
            )
            ScreenshotSeedData.seed(into: container.mainContext)
            return container
        }
        // UI-test-only synthetic failure injection, so `KurnUITests` can
        // exercise every classified `.recoveryRequired` reason without a
        // real full disk, incompatible store, or corrupt file. The launch
        // environment (not `.arguments`) carries which reason, matching
        // `XCUIApplication.launchEnvironment`. Compiled out of Release.
        if let reasonRaw = ProcessInfo.processInfo.environment["UI_TESTING_STORE_OPEN_FAILURE_REASON"],
           let reason = ModelStoreOpenFailureReason(rawValue: reasonRaw) {
            throw ModelStoreDebugInjection.error(for: reason)
        }
        #endif
        return try ModelContainerBootstrap.makeStore()
    }

    /// Builds every store-dependent coordinator and runs the launch/foreground
    /// recovery sweeps — exactly what used to run unconditionally in `init()`
    /// before this PR, now callable from either the synchronous (common) path
    /// or the deferred (locked-launch/recovery) path, so both converge on
    /// identical behavior once a container exists.
    @MainActor
    private static func makeAppEnvironment(container: ModelContainer, settings: AppSettings) -> AppEnvironment {
        let transcription = TranscriptionViewModel(modelContext: container.mainContext)
        let playbackEnhancement = PlaybackEnhancementViewModel(modelContext: container.mainContext)
        let semanticIndex = SemanticIndexCoordinator(modelContext: container.mainContext)
        let wiki = WikiCoordinator(modelContext: container.mainContext)

        // Lets `StartRecordingIntent` (Siri/Shortcuts/Control Center/Action
        // Button) create a meeting and queue it for `MeetingsListView` to
        // present, without any View having to hand it a `ModelContext`.
        RecordingLauncher.shared.configure(modelContext: container.mainContext, settings: settings)
        // Clean up after a process that died mid-recording (orphaned Live
        // Activity + an unsaved audio file with no matching `Recording` row).
        RecordingRecovery.recoverOrphans(modelContainer: container)
        // And after one that died mid-transcription: recordings stuck at
        // known on-device `.inProgress` work becomes `.pending`; cloud or
        // unknown work becomes `.failed` to prevent ambiguous paid replay.
        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)

        return AppEnvironment(
            modelContainer: container,
            transcription: transcription,
            playbackEnhancement: playbackEnhancement,
            semanticIndex: semanticIndex,
            wiki: wiki
        )
    }
}
