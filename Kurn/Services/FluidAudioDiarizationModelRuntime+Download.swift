import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio
#endif

extension FluidAudioDiarizationModelRuntime {
    static func download(
        _ model: FluidAudioDiarizationModel,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) async throws {
        #if canImport(FluidAudio)
        onProgress(ModelDownloadStatus(fractionCompleted: 0, phase: .preparing))
        let progressHandler: ProgressHandler = { progress in
            let phase: ModelDownloadPhase
            switch progress.phase {
            case .listing: phase = .preparing
            case .downloading: phase = .downloading
            case .compiling: phase = .compiling
            }
            onProgress(.scaled(progress.fractionCompleted, from: 0, to: 1, phase: phase))
        }
        switch model {
        case .pyannote:
            _ = try await OfflineDiarizerModels.load(progressHandler: progressHandler)
        case .nemotron3:
            _ = try await Nemotron3Models.loadFromHuggingFace(
                config: .fast32,
                cacheDirectory: ModelStore.modelsDirectory,
                computeUnits: .cpuAndNeuralEngine,
                progressHandler: progressHandler
            )
        }
        onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
        #else
        throw AppError.modelDownloadFailed(NSLocalizedString("settings.fluid_audio.package_missing", comment: ""))
        #endif
    }
}
