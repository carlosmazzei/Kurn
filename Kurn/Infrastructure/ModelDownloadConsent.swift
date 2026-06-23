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

enum ModelSet {
    case liveTranscriptionASR
    case diarization
}

struct ModelDownloadConsent {
    static func download(_ set: ModelSet) async throws {
        #if canImport(FluidAudio)
        do {
            switch set {
            case .liveTranscriptionASR:
                let engine = StreamingModelVariant.parakeetEou160ms.createManager()
                try await engine.loadModels()
            case .diarization:
                let manager = OfflineDiarizerManager()
                try await manager.prepareModels()
            }
        } catch {
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }
        #else
        throw AppError.modelDownloadRequired(
            NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        )
        #endif
    }
}
