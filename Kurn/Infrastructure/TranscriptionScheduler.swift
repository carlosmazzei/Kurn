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
//  This file holds every decision — what counts as interrupted work, whether
//  and how to submit, whether an opened window may run, and the resume pass
//  itself — so it is tested without `BGTaskScheduler`. The calls into
//  `BGTaskScheduler` live in `TranscriptionScheduler+BGTask.swift`.
//

import Foundation
import KurnCore
import SwiftData

#if canImport(BackgroundTasks)

/// What a background processing window needs from the running app: the open
/// store and the app's own transcription coordinator and settings — the same
/// instances the scene uses (`AppComposition`), so a run finished here gets the
/// same post-transcription indexing and wiki work as one finished in the
/// foreground, and cannot race a foreground run of the same recording.
@MainActor
struct BackgroundTranscriptionContext {
    let container: ModelContainer
    let transcription: TranscriptionCoordinator
    let settings: AppSettings
}

enum TranscriptionScheduler {

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let taskIdentifier = "ai.kurn.transcription.processing"

    /// What `scheduleIfWorkRemains` submits: one processing request, needing
    /// the network only when a Whisper upload is part of the backlog.
    struct SubmissionPlan: Equatable {
        var pendingCount: Int
        var requiresNetworkConnectivity: Bool
    }

    /// Whether to submit a processing request, and with what requirements.
    /// `nil` when the pipeline cannot run in the background or nothing is
    /// waiting. Includes `.inProgress`: at the moment the app backgrounds, an
    /// active run hasn't been paused yet — it parks as `.pending` when its
    /// grace window expires a few seconds later.
    @MainActor
    static func submissionPlan(context: ModelContext, settings: AppSettings) -> SubmissionPlan? {
        guard !pipelineUsesCoreML(settings.pipelineConfiguration) else {
            AppLog.transcription.atDebug.debug("bgTask: FluidAudio pipeline, not scheduling")
            return nil
        }
        let pending = interruptedRecordings(context: context)
        guard !pending.isEmpty else { return nil }
        // Whisper resumes need the network; a purely on-device backlog doesn't,
        // and requiring connectivity there would only delay scheduling.
        return SubmissionPlan(
            pendingCount: pending.count,
            requiresNetworkConnectivity: pending.contains { $0.transcriptionMode == .whisperAPI }
        )
    }

    /// What an opened processing window does first.
    enum WindowStart {
        /// The device is locked: the store and recordings are Data Protected
        /// and unreadable, which would turn every resume into a spurious
        /// failure. Try again in a later window.
        case deferWhileLocked
        /// Boot may still be `.waitingForProtectedData`/`.opening`/
        /// `.recoveryRequired` even with protected data available — nothing
        /// to resume against either way.
        case deferUntilStoreReady
        case run(BackgroundTranscriptionContext)
    }

    @MainActor
    static func windowStart(
        protectedDataAvailable: Bool,
        context: () -> BackgroundTranscriptionContext?
    ) -> WindowStart {
        guard protectedDataAvailable else { return .deferWhileLocked }
        guard let context = context() else { return .deferUntilStoreReady }
        return .run(context)
    }

    @MainActor
    static func pendingRecordings(context: ModelContext) -> [Recording] {
        let pendingRaw = TranscriptionStatus.pending.rawValue
        let readyRaw = RecordingCaptureState.ready.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate {
                $0.transcriptionStatusRaw == pendingRaw && $0.captureStateRaw == readyRaw
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    static func interruptedRecordings(context: ModelContext) -> [Recording] {
        let pendingRaw = TranscriptionStatus.pending.rawValue
        let inProgressRaw = TranscriptionStatus.inProgress.rawValue
        let readyRaw = RecordingCaptureState.ready.rawValue
        let descriptor = FetchDescriptor<Recording>(
            predicate: #Predicate {
                ($0.transcriptionStatusRaw == pendingRaw || $0.transcriptionStatusRaw == inProgressRaw)
                    && $0.captureStateRaw == readyRaw
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Whether any configured stage needs on-device GPU/ANE work that the system
    /// does not allow a backgrounded app to do — CoreML model compilation for the
    /// FluidAudio stages, Metal command submission for whisper.cpp. Scheduling a
    /// `BGProcessingTask` for these would burn the window on a guaranteed failure.
    static func pipelineUsesCoreML(_ config: PipelineConfiguration) -> Bool {
        config.transcription == .fluidAudioParakeet
            || config.transcription == .whisperCpp
            || config.vad == .fluidAudio
            || config.diarization == .fluidAudio
            || config.languageDetection == .fluidAudioLID
    }
}

/// Drives a background-window resume pass on the app's own coordinator, and
/// lets the expiration handler reach it without capturing non-`Sendable`
/// state.
@MainActor
final class BackgroundTranscriptionRunner {
    static let shared = BackgroundTranscriptionRunner()
    private var transcription: TranscriptionCoordinator?

    /// Resume every `.pending` recording, wait for the runs to finish (or be
    /// paused by `pause()`), re-arm the scheduler when a backlog remains, and
    /// return how many recordings are still pending. `reschedule` is the
    /// `BGTaskScheduler` submission; tests observe it instead.
    func run(
        _ context: BackgroundTranscriptionContext,
        reschedule: (BackgroundTranscriptionContext) -> Void = {
            TranscriptionScheduler.scheduleIfWorkRemains(container: $0.container, settings: $0.settings)
        }
    ) async -> Int {
        transcription = context.transcription
        context.transcription.resumePendingTranscriptions(settings: context.settings)
        await context.transcription.awaitActiveTranscriptions()
        transcription = nil

        let remaining = TranscriptionScheduler.pendingRecordings(context: context.container.mainContext).count
        if remaining > 0 {
            reschedule(context)
        }
        return remaining
    }

    func pause() {
        transcription?.cancelAllTranscriptions()
    }
}
#endif
