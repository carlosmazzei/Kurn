//
//  AppComposition.swift
//  Kurn
//
//  The app's composition root: the one place that builds the store-dependent
//  coordinators and wires them together, and the one owner of their instances
//  for the life of the process.
//
//  It exists because two entry points need the *same* objects. The scene reads
//  them through `KurnApp.appEnvironment`; a `BGProcessingTask` window
//  (`TranscriptionScheduler`) can fire in a background launch where no scene
//  has observed anything yet. The background runner used to build its own
//  `AppSettings` and transcription view model, whose semantic-index and wiki
//  coordinators were never set — so a transcription finished in the background
//  was silently left unindexed and without its wiki article — and the two
//  view models could only keep a recording from transcribing twice through a
//  process-global static. Dependencies are now passed at construction, never
//  assigned later, so no coordinator can run before it is wired.
//

import SwiftData

/// The app-wide state that only exists once the store has opened — every
/// coordinator `ContentView` and its descendants reach through the
/// environment.
@MainActor
struct AppEnvironment {
    let modelContainer: ModelContainer
    let transcription: TranscriptionCoordinator
    let summaries: SummaryViewModel
    let playbackEnhancement: PlaybackEnhancementViewModel
    let semanticIndex: SemanticIndexCoordinator
    let wiki: WikiCoordinator
}

@MainActor
final class AppComposition {
    let settings: AppSettings
    private var environment: AppEnvironment?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// The environment for `container`, built the first time it is asked for
    /// — from the synchronous launch path, the foreground-activation retry or
    /// a background processing window, whichever comes first — and returned
    /// unchanged afterwards. A different container (the store was replaced by
    /// a restore or a fresh start) gets a freshly built environment.
    func environment(for container: ModelContainer) -> AppEnvironment {
        if let environment, environment.modelContainer === container {
            return environment
        }
        let built = Self.makeEnvironment(container: container, settings: settings)
        Self.runLaunchSweeps(container: container, settings: settings)
        environment = built
        return built
    }

    /// Builds every store-dependent coordinator with its dependencies passed
    /// at construction. Pure wiring, no side effects — internal so the wiring
    /// itself is testable.
    static func makeEnvironment(container: ModelContainer, settings: AppSettings) -> AppEnvironment {
        let context = container.mainContext
        let semanticIndex = SemanticIndexCoordinator(modelContext: context, appSettings: settings)
        let wiki = WikiCoordinator(modelContext: context, appSettings: settings)
        let transcription = TranscriptionCoordinator(
            modelContext: context,
            appSettings: settings,
            semanticIndexCoordinator: semanticIndex,
            wikiCoordinator: wiki
        )
        return AppEnvironment(
            modelContainer: container,
            transcription: transcription,
            summaries: SummaryViewModel(modelContext: context, appSettings: settings),
            playbackEnhancement: PlaybackEnhancementViewModel(modelContext: context),
            semanticIndex: semanticIndex,
            wiki: wiki
        )
    }

    /// The launch recovery sweeps, run once per container so every entry point
    /// converges on identical behavior once a store exists.
    private static func runLaunchSweeps(container: ModelContainer, settings: AppSettings) {
        let context = container.mainContext

        // Lets `StartRecordingIntent` (Siri/Shortcuts/Control Center/Action
        // Button) create a meeting and queue it for `MeetingsListView` to
        // present, without any View having to hand it a `ModelContext`.
        RecordingLauncher.shared.configure(modelContext: context, settings: settings)
        // Clean up after a process that died mid-recording (orphaned Live
        // Activity + an unsaved audio file with no matching `Recording` row).
        RecordingRecovery.recoverOrphans(modelContainer: container)
        // Reconcile any delete or replace whose trash-then-purge was
        // interrupted by a process death. Journaled operations resolve from
        // their own durable record (replay forward past a committed mutation,
        // roll back an uncommitted one — see `RecordingOperationJournal`'s
        // header comment); the sweep remains as the heuristic fallback for
        // pre-journal trash folders.
        RecordingOperationJournal.replay(context: context)
        RecordingTrash.sweep(context: context)
        // And after one that died mid-transcription: recordings stuck at
        // known on-device `.inProgress` work becomes `.pending`; cloud or
        // unknown work becomes `.failed` to prevent ambiguous paid replay.
        TranscriptionRecovery.sweepStaleTranscriptions(modelContainer: container)
    }
}
