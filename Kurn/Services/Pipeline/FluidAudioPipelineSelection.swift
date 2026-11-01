import KurnCore

struct FluidAudioPipelineSelection {
    static func validateASR(config: PipelineConfiguration, language: MeetingLanguage) throws {
        guard config.transcription == .fluidAudioParakeet else { return }
        guard config.fluidAudioASRModel.supports(language) else {
            throw AppError.transcriptionLanguageUnsupported(language, .fluidAudioParakeet)
        }
        if config.fluidAudioASRModel != .parakeetV3 && !config.fluidAudioASRConsented {
            throw AppError.modelDownloadRequired(config.fluidAudioASRModel.displayName)
        }
    }

    static func requiredModelSets(for config: PipelineConfiguration) -> [ModelSet] {
        let diarization = config.effectiveDiarization == .fluidAudio
            ? config.fluidAudioDiarizationModel.requiredModelSet
            : config.effectiveDiarization.requiredModelSet
        return [
            config.transcription.requiredModelSet(
                whisperCppModel: config.whisperCppModel,
                fluidAudioASRModel: config.fluidAudioASRModel
            ),
            config.languageDetection.requiredModelSet,
            config.vad.requiredModelSet,
            diarization
        ].compactMap { $0 }
    }

    static func runtimeNetworkModelSets(for config: PipelineConfiguration) -> [ModelSet] {
        requiredModelSets(for: config).filter { set in
            switch set {
            case .vad: true
            case .onDeviceASR, .diarization, .liveTranscriptionASR, .whisperCppASR, .sherpaOnnxDiarization,
                 .fluidAudioASR, .fluidAudioDiarization, .fluidAudioUnifiedStreaming: false
            }
        }
    }

    static func checkpointProviderID(
        engine: TranscriptionEngine,
        provider: AIProvider,
        whisperCppModel: WhisperCppModel,
        fluidAudioASRModel: FluidAudioASRModel
    ) -> String? {
        switch engine {
        case .whisperAPI: provider.id
        case .whisperCpp: "whispercpp:\(whisperCppModel.rawValue)"
        case .fluidAudioParakeet: fluidAudioASRModel.checkpointProviderID
        case .appleSpeech: nil
        }
    }
}
