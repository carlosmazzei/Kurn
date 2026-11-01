import Foundation
import KurnCore

extension ModelDownloadConsent {
    static func downloadFluidAudioVariant(
        _ set: ModelSet,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) async throws {
        guard set.isFluidAudioVariant else {
            throw AppError.modelDownloadRequired(TranscriptionEngine.fluidAudioParakeet.displayName)
        }
        #if canImport(FluidAudio)
        switch set {
        case .fluidAudioASR(let model):
            try await FluidAudioASRModelRuntime.download(model, onProgress: onProgress)
        case .fluidAudioDiarization(let model):
            try await FluidAudioDiarizationModelRuntime.download(model, onProgress: onProgress)
        case .fluidAudioUnifiedStreaming:
            try await FluidAudioASRModelRuntime.downloadUnifiedStreaming(onProgress: onProgress)
        default:
            throw AppError.modelDownloadRequired(TranscriptionEngine.fluidAudioParakeet.displayName)
        }
        #else
        throw AppError.modelDownloadRequired(
            NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        )
        #endif
    }
}
