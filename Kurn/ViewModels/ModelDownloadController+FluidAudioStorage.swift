import KurnCore

extension ModelDownloadController {
    func handleDeletedFluidAudioVariant(_ model: ModelStore.InstalledModel, settings: AppSettings) {
        switch model.group {
        case .fluidAudioASR:
            let removed = FluidAudioASRModel.allCases.filter {
                $0 != .parakeetV3 && model.folderNames.contains($0.folderName)
            }
            settings.fluidAudioASRModelConsents.subtract(removed.map(\.rawValue))
            if removed.contains(settings.fluidAudioASRModel) {
                settings.fluidAudioASRModel = .parakeetV3
                if settings.transcriptionEngine == .fluidAudioParakeet &&
                    !(settings.fluidAudioBatchASRModelsConsented && isFluidAudioASRInstalled(.parakeetV3)) {
                    settings.transcriptionEngine = .appleSpeech
                }
            }
            if removed.contains(.nemotronUnified) {
                settings.fluidAudioUnifiedStreamingConsented = false
                if settings.fluidAudioLiveModel == .nemotronUnified {
                    settings.liveTranscriptionEnabled = false
                    settings.fluidAudioLiveModel = .automatic
                }
            }
        case .nemotronDiarization:
            handleDeletedNemotronDiarization(settings: settings)
        default:
            break
        }
    }

    func disableDeletedLegacyFluidAudioLive(settings: AppSettings) {
        if settings.fluidAudioLiveModel == .automatic { settings.liveTranscriptionEnabled = false }
    }

    func disableDeletedLegacyFluidAudioDiarization(settings: AppSettings) {
        if settings.diarizationEngine == .fluidAudio && settings.fluidAudioDiarizationModel == .pyannote {
            settings.diarizationEngine = .heuristic
        }
    }

    private func handleDeletedNemotronDiarization(settings: AppSettings) {
        settings.fluidAudioNemotronModelsConsented = false
        if settings.fluidAudioDiarizationModel == .nemotron3 {
            settings.fluidAudioDiarizationModel = .pyannote
            if settings.diarizationEngine == .fluidAudio &&
                !(settings.fluidAudioDiarizationModelsConsented && isFluidAudioDiarizationInstalled(.pyannote)) {
                settings.diarizationEngine = .heuristic
            }
        }
    }
}
