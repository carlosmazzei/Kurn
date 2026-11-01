import Foundation
import KurnCore

enum FluidAudioModelSelection {
    case asr(FluidAudioASRModel, selectEngine: Bool)
    case diarization(FluidAudioDiarizationModel, selectEngine: Bool)
    case live(FluidAudioLiveModel, enable: Bool)

    var modelSet: ModelSet {
        switch self {
        case .asr(let model, _): return model.requiredModelSet
        case .diarization(let model, _): return model.requiredModelSet
        case .live(let model, _): return model.requiredModelSet
        }
    }

    var group: ModelStore.ModelGroup {
        switch self {
        case .asr(let model, _): return model == .parakeetV3 ? .onDeviceLanguage : .fluidAudioASR
        case .diarization(let model, _): return model == .pyannote ? .diarization : .nemotronDiarization
        case .live(let model, _): return model == .automatic ? .liveTranscription : .fluidAudioASR
        }
    }

    var displayName: String {
        switch self {
        case .asr(let model, _): return model.displayName
        case .diarization(let model, _): return model.displayName
        case .live(let model, _): return model.displayName
        }
    }

    var approximateBytes: Int64 {
        switch self {
        case .asr(let model, _): return model.approximateBytes
        case .diarization(let model, _): return model.approximateBytes
        case .live: return FluidAudioASRModel.nemotronUnified.approximateBytes
        }
    }

    @MainActor
    func isInstalled(using controller: ModelDownloadController) -> Bool {
        switch self {
        case .asr(let model, _): return controller.isFluidAudioASRInstalled(model)
        case .diarization(let model, _): return controller.isFluidAudioDiarizationInstalled(model)
        case .live(.automatic, _): return controller.isAutomaticFluidAudioLiveInstalled()
        case .live(.nemotronUnified, _): return controller.isFluidAudioUnifiedStreamingInstalled()
        }
    }

    @MainActor
    func hasLegacyConsent(settings: AppSettings) -> Bool {
        switch modelSet {
        case .onDeviceASR: return settings.fluidAudioBatchASRModelsConsented
        case .diarization: return settings.fluidAudioDiarizationModelsConsented
        case .liveTranscriptionASR: return settings.fluidAudioASRModelsConsented
        default: return false
        }
    }

    @MainActor
    func apply(settings: AppSettings) {
        switch self {
        case .asr(let model, let selectEngine):
            settings.fluidAudioASRModel = model
            if model == .parakeetV3 {
                settings.fluidAudioBatchASRModelsConsented = true
            } else {
                settings.fluidAudioASRModelConsents.insert(model.rawValue)
            }
            if selectEngine { settings.transcriptionEngine = .fluidAudioParakeet }
        case .diarization(let model, let selectEngine):
            settings.fluidAudioDiarizationModel = model
            if model == .pyannote {
                settings.fluidAudioDiarizationModelsConsented = true
            } else {
                settings.fluidAudioNemotronModelsConsented = true
            }
            if selectEngine { settings.diarizationEngine = .fluidAudio }
        case .live(let model, let enable):
            settings.fluidAudioLiveModel = model
            if model == .automatic {
                settings.fluidAudioASRModelsConsented = true
            } else {
                settings.fluidAudioUnifiedStreamingConsented = true
            }
            if enable { settings.liveTranscriptionEnabled = true }
        }
    }
}
