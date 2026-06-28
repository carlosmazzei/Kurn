//
//  FluidAudioModelStore.swift
//  Kurn
//
//  Process-wide cache for the expensive-to-load FluidAudio Parakeet ASR model.
//  Loading the model compiles CoreML/ANE artifacts that can take tens of seconds
//  on first use, so it must happen exactly once and be reused everywhere:
//  across recordings, across meeting views (each builds its own
//  `TranscriptionViewModel` → `TranscriptionService`), and across the two
//  consumers that both run Parakeet — the transcriber and the auto-language
//  detector — which would otherwise each load a separate copy.
//
//  Pair this with `prewarm()` from the foreground so the one-time ANE
//  compilation happens while the app is active (the ANE compiler daemon is not
//  reachable from a backgrounded process, which is what surfaces as
//  "failed to compile ANE model" / "could not communicate with a helper
//  application" mid-transcription).
//

import Foundation

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioModelStore {
    static let shared = FluidAudioModelStore()

    private var manager: AsrManager?
    /// In-flight load, so concurrent callers await one load instead of racing to
    /// start several (e.g. language detection and transcription firing together).
    private var loadTask: Task<AsrManager, Error>?

    private init() {}

    /// The shared manager, loaded on first call. Concurrent callers coalesce onto
    /// the same in-flight load. Failures aren't cached — the next call retries.
    func manager() async throws -> AsrManager {
        try await ResourceGuard.requireModelDownloadHeadroom()
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        let task = Task<AsrManager, Error> {
            try await ResourceGuard.requireModelDownloadHeadroom()
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            return AsrManager(config: .default, models: models)
        }
        loadTask = task
        do {
            let created = try await task.value
            manager = created
            loadTask = nil
            AppLog.transcription.atNotice.notice("fluidAudio: multilingual ASR models loaded (shared)")
            return created
        } catch {
            loadTask = nil
            AppLog.transcription.atError.error("fluidAudio: model load failed: \(error.localizedDescription, privacy: .public)")
            if let appError = ResourceGuard.appErrorIfResourceFailure(error) {
                throw appError
            }
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }
    }

    /// Best-effort foreground warm-up: trigger the costly first load/ANE
    /// compilation now instead of lazily mid-transcription. Errors are swallowed;
    /// the real transcription path surfaces them if loading still fails later.
    func prewarm() async {
        _ = try? await manager()
    }
}

#endif
