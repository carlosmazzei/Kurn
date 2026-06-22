//
//  ModelDownloadConsent.swift
//  Kurn
//
//  Single place that downloads FluidAudio's CoreML models after the user
//  consents in Settings. Each `ModelSet` case only triggers its own model
//  family's download — enabling live transcription never fetches the
//  diarization models, and vice versa.
//

import FluidAudio
import Foundation

enum ModelSet {
    case liveTranscriptionASR
    case diarization
}

struct ModelDownloadConsent {
    static func download(_ set: ModelSet) async throws {
        switch set {
        case .liveTranscriptionASR:
            let engine = StreamingModelVariant.parakeetEou160ms.createManager()
            try await engine.loadModels()
        case .diarization:
            let manager = OfflineDiarizerManager()
            try await manager.prepareModels()
        }
    }
}
