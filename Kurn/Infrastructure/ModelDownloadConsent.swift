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
    case onDeviceASR
    case diarization
}

struct ModelDownloadConsent {
    static func download(_ set: ModelSet) async throws {
        #if canImport(FluidAudio)
        do {
            switch set {
            case .liveTranscriptionASR:
                // The live preview picks a streaming model per meeting language at
                // record time (English-only EOU vs. multilingual), so warm both
                // now — the recording path must never block on a missing model.
                let englishEngine = StreamingModelVariant.parakeetEou160ms.createManager()
                try await englishEngine.loadModels()
                let multilingualEngine = FluidAudioMultilingualStreamingManager()
                try await multilingualEngine.loadModels()
            case .onDeviceASR:
                // Multilingual on-device batch ASR (Parakeet TDT v3) used for the
                // post-recording transcript when the meeting language is "Auto".
                _ = try await AsrModels.downloadAndLoad(version: .v3)
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
