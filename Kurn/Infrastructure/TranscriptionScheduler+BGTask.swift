//
//  TranscriptionScheduler+BGTask.swift
//  Kurn
//
//  The `BGTaskScheduler` half of `TranscriptionScheduler`: registering the
//  launch handler, submitting requests and completing tasks. Only an
//  adapter — what to submit, whether a window may run and the resume pass
//  are decided in `TranscriptionScheduler.swift`, where they are tested;
//  `BGTaskScheduler` itself only works in a real app launch.
//

import Foundation
import KurnCore
import SwiftData

#if canImport(BackgroundTasks)
import BackgroundTasks
#if canImport(UIKit)
import UIKit
#endif

extension TranscriptionScheduler {

    /// Register the launch handler. Must be called before the app finishes
    /// launching (`KurnApp.init`) — and, per the H2 boot state machine
    /// (docs/resilience-megaplan.md), before the store has even been opened:
    /// `contextProvider` is only consulted when a task actually fires (from
    /// the main actor, alongside the existing protected-data check), not at
    /// registration time, so registration itself never needs a container to
    /// exist yet. A background-only launch while the device is locked
    /// registers this handler and then never attempts to open the store at
    /// all until the scene becomes active.
    static func register(contextProvider: @escaping @MainActor @Sendable () -> BackgroundTranscriptionContext?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task, contextProvider: contextProvider)
        }
    }

    /// Submit a processing request when interrupted transcriptions are waiting
    /// and the configured pipeline can actually run in the background. Called
    /// on every background transition; resubmitting replaces the earlier
    /// request, so it's safe to call repeatedly.
    @MainActor
    static func scheduleIfWorkRemains(container: ModelContainer, settings: AppSettings) {
        guard let plan = submissionPlan(context: container.mainContext, settings: settings) else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = plan.requiresNetworkConnectivity
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLog.transcription.atNotice.notice("bgTask: scheduled for \(plan.pendingCount, privacy: .public) pending recording(s)")
        } catch {
            AppLog.transcription.atError.error("bgTask: submit failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
        }
    }

    /// `BGTask` isn't `Sendable`, so the completion call crosses into the
    /// main-actor work task inside an unchecked box; `setTaskCompleted` and
    /// `expirationHandler` are documented as callable from any thread.
    private static func handle(
        _ task: BGProcessingTask,
        contextProvider: @escaping @MainActor @Sendable () -> BackgroundTranscriptionContext?
    ) {
        AppLog.transcription.atNotice.notice("bgTask: window started")
        task.expirationHandler = {
            // Cooperative shutdown: each run checkpoints and parks as
            // `.pending`, then `awaitActiveTranscriptions` returns in `run`.
            AppLog.transcription.atNotice.notice("bgTask: window expiring, pausing runs")
            Task { @MainActor in BackgroundTranscriptionRunner.shared.pause() }
        }
        let box = UncheckedSendableBox(task)
        Task { @MainActor in
            #if canImport(UIKit)
            let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
            #else
            let protectedDataAvailable = true
            #endif
            switch windowStart(protectedDataAvailable: protectedDataAvailable, context: contextProvider) {
            case .deferWhileLocked:
                AppLog.transcription.atNotice.notice("bgTask: protected data unavailable (locked), deferring")
                resubmit()
                box.value.setTaskCompleted(success: false)
            case .deferUntilStoreReady:
                AppLog.transcription.atNotice.notice("bgTask: store not ready, deferring")
                resubmit()
                box.value.setTaskCompleted(success: false)
            case .run(let context):
                let remaining = await BackgroundTranscriptionRunner.shared.run(context)
                AppLog.transcription.atNotice.notice("bgTask: window finished, remaining=\(remaining, privacy: .public)")
                box.value.setTaskCompleted(success: remaining == 0)
            }
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
}

/// Crosses a non-`Sendable` value between isolation domains when the
/// underlying API is documented thread-safe.
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#endif
