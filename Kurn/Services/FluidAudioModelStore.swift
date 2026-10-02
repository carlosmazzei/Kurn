//
//  FluidAudioModelStore.swift
//  Kurn
//
//  Process-wide cache for the expensive-to-load FluidAudio Parakeet ASR model.
//  Loading the model compiles CoreML/ANE artifacts that can take tens of seconds
//  on first use, so it must happen exactly once and be reused everywhere:
//  across recordings, across meeting views (each builds its own
//  `TranscriptionCoordinator` → `TranscriptionService`), and across the two
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
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioModelStore {
    static let shared = FluidAudioModelStore()

    /// FluidAudio 0.15.5's long-form profile for multilingual meeting audio.
    ///
    /// The package default keeps `melChunkContext` enabled to protect English
    /// chunk boundaries, but its v3 guidance recommends disabling that prepend
    /// for multilingual long-form audio because it can pull the decoder toward
    /// its English prior. Dual-decode arbitration probes the available chunking
    /// strategies once per file and commits to the best result; meeting
    /// transcription prioritizes that quality gain over its modest overhead.
    static let transcriptionConfig = ASRConfig(
        parallelChunkConcurrency: 4,
        streamingEnabled: true,
        melChunkContext: false,
        dualDecodeArbitration: true
    )

    /// Loads once, coalesces concurrent callers (e.g. language detection and
    /// transcription firing together) onto one load, and never caches a failure.
    private let loader = CoalescedLoader<AsrManager>()

    private init() {}

    /// The shared manager, loaded on first call. Failures aren't cached — the
    /// next call retries.
    func manager() async throws -> AsrManager {
        try await ResourceGuard.requireModelDownloadHeadroom()
        if let manager = await loader.current { return manager }
        do {
            let manager = try await loader.value {
                try await ResourceGuard.requireModelDownloadHeadroom()
                // H8 PR 17: acquired once for the whole coalesced load, not per
                // caller — concurrent callers already await this one load
                // rather than each starting their own.
                return try await withResourceReservation(.modelLoading) {
                    let models = try await AsrModels.downloadAndLoad(version: .v3)
                    return AsrManager(config: Self.transcriptionConfig, models: models)
                }
            }
            AppLog.transcription.atNotice.notice("fluidAudio: multilingual ASR models ready (shared)")
            return manager
        } catch {
            AppLog.transcription.atError.error("fluidAudio: model load failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            try ResourceGuard.rethrowIfResourceFailure(error)
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
