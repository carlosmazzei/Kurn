//
//  ModelDownloadConsent.swift
//  Kurn
//
//  Single place that downloads FluidAudio's CoreML models after the user
//  consents in Settings. Each `ModelSet` case only triggers its own model
//  family's download — enabling live transcription never fetches the
//  diarization models, and vice versa.
//

import Foundation

#if canImport(FluidAudio)
import FluidAudio
#endif

enum ModelSet: Sendable, Equatable {
    case liveTranscriptionASR
    case onDeviceASR
    case diarization
    case vad
    /// whisper.cpp GGML weights. Carries the variant because, unlike the
    /// FluidAudio sets, the user chooses which weight file to download.
    case whisperCppASR(WhisperCppModel)
}

enum ModelDownloadPhase: Sendable, Equatable {
    case preparing
    case downloading
    case compiling
}

struct ModelDownloadStatus: Sendable, Equatable {
    var fractionCompleted: Double
    var phase: ModelDownloadPhase
}

struct ModelDownloadConsent {
    static func download(
        _ set: ModelSet,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void = { _ in }
    ) async throws {
        try await ResourceGuard.requireModelDownloadHeadroom()
        // Handled before the FluidAudio branch below: whisper.cpp brings its own
        // downloader, so this set must work in a build without FluidAudio linked.
        if case .whisperCppASR(let model) = set {
            try await WhisperCppModelDownloader.download(model, onProgress: onProgress)
            try await ResourceGuard.requireModelDownloadHeadroom()
            return
        }
        #if canImport(FluidAudio)
        do {
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
                    progressHandler: progressHandler(onProgress)
                )
            case .diarization:
                _ = try await OfflineDiarizerModels.load(
                    progressHandler: progressHandler(onProgress)
                )
            case .vad:
                // Silero VAD CoreML model; `VadManager`'s initializer downloads
                // and loads it on first use.
                _ = try await VadManager(progressHandler: progressHandler(onProgress))
            case .whisperCppASR:
                // Unreachable — returned above, before this branch.
                break
            }
            onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
            try await ResourceGuard.requireModelDownloadHeadroom()
        } catch let appError as AppError {
            throw appError
        } catch {
            try ResourceGuard.rethrowIfResourceFailure(error)
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }
        #else
        throw AppError.modelDownloadRequired(
            NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        )
        #endif
    }

    #if canImport(FluidAudio)
    private static func progressHandler(
        _ onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) -> ProgressHandler {
        scaledProgress(from: 0, to: 1, onProgress: onProgress)
    }

    private static func scaledProgress(
        from lowerBound: Double,
        to upperBound: Double,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) -> ProgressHandler {
        { progress in
            let fraction = min(1, max(0, progress.fractionCompleted))
            let scaled = lowerBound + fraction * (upperBound - lowerBound)
            let phase: ModelDownloadPhase
            switch progress.phase {
            case .listing:
                phase = .preparing
            case .downloading:
                phase = .downloading
            case .compiling:
                phase = .compiling
            }
            onProgress(ModelDownloadStatus(fractionCompleted: scaled, phase: phase))
        }
    }
    #endif
}
