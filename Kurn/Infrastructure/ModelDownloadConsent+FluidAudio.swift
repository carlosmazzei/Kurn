//
//  ModelDownloadConsent+FluidAudio.swift
//  Kurn
//
//  The FluidAudio half of `ModelDownloadConsent.download`: fetching and
//  loading each model family's CoreML bundle. Only an adapter — which set
//  downloads, the network policy, progress scaling and how a failure is
//  reported all live in `ModelDownloadConsent.swift`, where they are tested;
//  what is left here needs a real download and the Neural Engine.
//

import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

extension ModelDownloadConsent {
    static func downloadFluidAudioModels(
        _ set: ModelSet,
        policy: LargeTransferPolicy,
        network: some NetworkPathSnapshotProviding,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) async throws {
        do {
            // H8 PR 17: reserved for the whole download+load, released in
            // the same flow whichever way it exits — see `ResourceScheduler`.
            try await withResourceReservation(.modelLoading) {
                try await loadFluidAudioModels(set, onProgress: onProgress)
            }
        } catch {
            throw downloadFailure(for: error, policy: policy, snapshot: network.snapshot)
        }
    }

    private static func loadFluidAudioModels(
        _ set: ModelSet,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) async throws {
        onProgress(ModelDownloadStatus(fractionCompleted: 0, phase: .preparing))
        switch set {
        case .liveTranscriptionASR:
            // The live preview picks a streaming model per meeting language at
            // record time (English-only EOU vs. multilingual), so warm both
            // now — the recording path must never block on a missing model.
            let englishEngine = StreamingEouAsrManager(chunkSize: .ms160)
            try await englishEngine.loadModels(progressHandler: scaledProgress(
                from: 0,
                to: 0.5,
                onProgress: onProgress
            ))
            let multilingualEngine = FluidAudioMultilingualStreamingManager()
            try await multilingualEngine.loadModels(progressHandler: scaledProgress(
                from: 0.5,
                to: 1,
                onProgress: onProgress
            ))
        case .onDeviceASR:
            // Multilingual on-device batch ASR (Parakeet TDT v3) used for the
            // post-recording transcript when the meeting language is "Auto".
            _ = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: scaledProgress(from: 0, to: 1, onProgress: onProgress)
            )
        case .diarization:
            _ = try await OfflineDiarizerModels.load(
                progressHandler: scaledProgress(from: 0, to: 1, onProgress: onProgress)
            )
        case .vad:
            // Silero VAD CoreML model; `VadManager`'s initializer downloads
            // and loads it on first use.
            _ = try await VadManager(progressHandler: scaledProgress(from: 0, to: 1, onProgress: onProgress))
        case .whisperCppASR, .sherpaOnnxDiarization:
            // Unreachable — `download` returned for both before reaching here.
            break
        }
        onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
        try await ResourceGuard.requireModelDownloadHeadroom()
    }

    private static func scaledProgress(
        from lowerBound: Double,
        to upperBound: Double,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) -> ProgressHandler {
        { progress in
            let phase: ModelDownloadPhase
            switch progress.phase {
            case .listing: phase = .preparing
            case .downloading: phase = .downloading
            case .compiling: phase = .compiling
            }
            onProgress(.scaled(progress.fractionCompleted, from: lowerBound, to: upperBound, phase: phase))
        }
    }
}
#endif
