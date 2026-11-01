import KurnCore

extension ModelSet {
    var isFluidAudioVariant: Bool {
        switch self {
        case .fluidAudioASR, .fluidAudioDiarization, .fluidAudioUnifiedStreaming: return true
        default: return false
        }
    }
}

extension FluidAudioASRModel {
    var requiredModelSet: ModelSet {
        self == .parakeetV3 ? .onDeviceASR : .fluidAudioASR(self)
    }
}

extension FluidAudioDiarizationModel {
    var requiredModelSet: ModelSet {
        self == .pyannote ? .diarization : .fluidAudioDiarization(self)
    }
}

extension FluidAudioLiveModel {
    var requiredModelSet: ModelSet {
        self == .automatic ? .liveTranscriptionASR : .fluidAudioUnifiedStreaming
    }
}
