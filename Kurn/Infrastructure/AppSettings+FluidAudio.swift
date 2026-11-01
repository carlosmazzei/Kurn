import KurnCore

extension AppSettings {
    var selectedFluidAudioASRModelsConsented: Bool {
        fluidAudioASRModel == .parakeetV3
            ? fluidAudioBatchASRModelsConsented
            : fluidAudioASRModelConsents.contains(fluidAudioASRModel.rawValue)
    }

    var selectedFluidDiarizationConsented: Bool {
        fluidAudioDiarizationModel == .pyannote
            ? fluidAudioDiarizationModelsConsented
            : fluidAudioNemotronModelsConsented
    }

    var selectedFluidAudioLiveModelsConsented: Bool {
        fluidAudioLiveModel == .automatic
            ? fluidAudioASRModelsConsented
            : fluidAudioUnifiedStreamingConsented
    }
}
