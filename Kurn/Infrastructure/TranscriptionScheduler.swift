//
//  TranscriptionScheduler.swift
//  Kurn
//
//  Schedules a `BGProcessingTask` to advance interrupted (`.pending`)
//  transcriptions while the app is in the background. This is an accelerator,
//  not a guarantee: iOS decides when (and whether) the task runs — typically
//  when the device is idle, often charging — and grants a window of minutes.
//  Whatever the window doesn't finish is checkpointed back to `.pending`, and
//  the foreground resume pass in `KurnApp` remains the reliable path.
//
//  Runs are skipped entirely when the pipeline uses FluidAudio CoreML stages:
//  compiling those models from the background fails outright ("could not
//  communicate with a helper application"), which would either fail the run or
//  silently degrade diarization quality.
//

import Foundation
import SwiftData

#if canImport(BackgroundTasks)
import BackgroundTasks
#if canImport(UIKit)
import UIKit
#endif

enum TranscriptionScheduler {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "ai.kurn.transcription.processing"

    /// Register the launch handler. Must be called before the app finishes
    /// launching (`KurnApp.init`).
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task, container: container)
        }
    }

    /// Submit a processing request when interrupted transcriptions are waiting
    /// and the configured pipeline can actually run in the background. Called
    /// on every background transition; resubmitting replaces the earlier
    /// request, so it's safe to call repeatedly.
    @MainActor
    static func scheduleIfWorkRemains(container: ModelContainer, settings: AppSettings) {
        guard !pipelineUsesCoreML(settings.pipelineConfiguration) else {
            AppLog.transcription.atDebug.debug("bgTask: FluidAudio pipeline, not scheduling")
            return
        }
        // Include `.inProgress`: at the moment the app backgrounds, an active
        // run hasn't been paused yet — it parks as `.pending` when its grace
        // window expires a few seconds later.
        let pending = interruptedRecordings(context: container.mainContext)
        guard !pending.isEmpty else { return }

        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        // Whisper resumes need the network; a purely on-device backlog doesn't,
        // and requiring connectivity there would only delay scheduling.
        request.requiresNetworkConnectivity = pending.contains { $0.transcriptionMode == .whisperAPI }
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLog.transcription.atNotice.notice("bgTask: scheduled for \(pending.count, privacy: .public) pending recording(s)")
        } catch {
            AppLog.transcription.atError.error("bgTask: submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Task handling

    /// `BGTask` isn't `Sendable`, so the completion call crosses into the
    /// main-actor work task inside an unchecked box; `setTaskCompleted` and
    /// `expirationHandler` are documented as callable from any thread.
    private static func handle(_ task: BGProcessingTask, container: ModelContainer) {
        AppLog.transcription.atNotice.notice("bgTask: window started")
        task.expirationHandler = {
            // Cooperative shutdown: each run checkpoints and parks as
            // `.pending`, then `awaitActiveTranscriptions` returns in `run`.
            AppLog.transcription.atNotice.notice("bgTask: window expiring, pausing runs")
            Task { @MainActor in BackgroundTranscriptionRunner.shared.pause() }
        }
        let box = UncheckedSendableBox(task)
        Task { @MainActor in
            // Processing windows usually open while the device is locked
            // (idle, charging) — but the store and the recordings are Data
            // Protected and unreadable then, which would turn every resume
            // into a spurious failure. Try again in a later window instead.
            #if canImport(UIKit)
            guard UIApplication.shared.isProtectedDataAvailable else {
                AppLog.transcription.atNotice.notice("bgTask: protected data unavailable (locked), deferring")
                resubmit()
                box.value.setTaskCompleted(success: false)
                return
            }
            #endif
            let remaining = await BackgroundTranscriptionRunner.shared.run(container: container)
            AppLog.transcription.atNotice.notice("bgTask: window finished, remaining=\(remaining, privacy: .public)")
            box.value.setTaskCompleted(success: remaining == 0)
        }
    }

    /// Re-arm a processing request without touching the (possibly unreadable)
    /// store. Network connectivity is required pessimistically — the common
    /// backlog is Whisper chunks, and an on-device backlog just waits for the
    /// next foreground pass instead.
    @MainActor
    private static func resubmit() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    fileprivate static func pendingRecordings(context: ModelContext) -> [Recording] {
        let pendingRaw = TranscriptionStatus.pending.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.transcriptionStatusRaw == pendingRaw }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    private static func interruptedRecordings(context: ModelContext) -> [Recording] {
        let pendingRaw = TranscriptionStatus.pending.rawValue
        let inProgressRaw = TranscriptionStatus.inProgress.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate {
                $0.transcriptionStatusRaw == pendingRaw || $0.transcriptionStatusRaw == inProgressRaw
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Whether any configured stage needs a FluidAudio CoreML model, which
    /// cannot be compiled from the background.
    private static func pipelineUsesCoreML(_ config: PipelineConfiguration) -> Bool {
        config.transcription == .fluidAudioParakeet
            || config.vad == .fluidAudio
            || config.diarization == .fluidAudio
            || config.languageDetection == .fluidAudioLID
    }
}

/// Owns the view model for a background-window resume pass so the expiration
/// handler can reach it without capturing non-`Sendable` state.
@MainActor
private final class BackgroundTranscriptionRunner {
    static let shared = BackgroundTranscriptionRunner()
    private var viewModel: TranscriptionViewModel?

    /// Resume every `.pending` recording, wait for the runs to finish (or be
    /// paused by `pause()`), re-arm the scheduler when a backlog remains, and
    /// return how many recordings are still pending.
    func run(container: ModelContainer) async -> Int {
        // Fresh instances: the handler can fire in a background launch where
        // no UI (and no app-level view model) exists. AppSettings reads the
        // persisted preferences.
        let settings = AppSettings()
        let vm = TranscriptionViewModel(modelContext: container.mainContext)
        viewModel = vm
        vm.resumePendingTranscriptions(settings: settings)
        await vm.awaitActiveTranscriptions()
        viewModel = nil

        let remaining = TranscriptionScheduler.pendingRecordings(context: container.mainContext).count
        if remaining > 0 {
            TranscriptionScheduler.scheduleIfWorkRemains(container: container, settings: settings)
        }
        return remaining
    }

    func pause() {
        viewModel?.cancelAllTranscriptions()
    }
}

/// Crosses a non-`Sendable` value between isolation domains when the
/// underlying API is documented thread-safe.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#endif
