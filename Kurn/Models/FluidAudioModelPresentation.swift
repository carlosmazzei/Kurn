import Foundation
import KurnCore

enum FluidAudioModelPresentation {
    enum DownloadSection: Equatable {
        case transcription
        case diarization
        case live
    }

    struct DownloadActionState: Equatable {
        let isVisible: Bool
        let isEnabled: Bool
    }

    static func sizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func modelLabel(name: String, approximateBytes: Int64) -> String {
        String(
            format: NSLocalizedString("settings.fluid_audio.model_size", comment: ""),
            name,
            sizeLabel(approximateBytes)
        )
    }

    static func liveModelLabel(_ model: FluidAudioLiveModel) -> String {
        if model == .automatic {
            return String(
                format: NSLocalizedString("settings.fluid_audio.live_automatic", comment: ""),
                model.displayName
            )
        }
        return modelLabel(name: model.displayName, approximateBytes: FluidAudioASRModel.nemotronUnified.approximateBytes)
    }

    static func batchSizeLabel(_ batchSize: FluidAudioSegmentationBatchSize) -> String {
        if batchSize == .recommended {
            return String(
                format: NSLocalizedString("settings.fluid_audio.batch_recommended", comment: ""),
                batchSize.rawValue
            )
        }
        return String(batchSize.rawValue)
    }

    static func canSelectASRModel(_ model: FluidAudioASRModel, language: MeetingLanguage, isDownloading: Bool) -> Bool {
        !isDownloading && model.supports(language)
    }

    static func canSelectLiveModel(_ model: FluidAudioLiveModel, language: MeetingLanguage, isDownloading: Bool) -> Bool {
        !isDownloading && (model == .automatic || model.supports(language))
    }

    static func liveLanguageGuidance(_ model: FluidAudioLiveModel, language: MeetingLanguage) -> String? {
        guard model != .automatic, !model.supports(language) else { return nil }
        return String(
            format: NSLocalizedString("error.transcription_language_unsupported", comment: ""),
            language.displayName,
            model.displayName
        )
    }

    static func isLiveModelInstalled(
        _ model: FluidAudioLiveModel,
        automaticInstalled: () -> Bool,
        unifiedInstalled: () -> Bool
    ) -> Bool {
        switch model {
        case .automatic: return automaticInstalled()
        case .nemotronUnified: return unifiedInstalled()
        }
    }

    static func downloadActionState(isInstalled: Bool, isSelectionEnabled: Bool) -> DownloadActionState {
        DownloadActionState(isVisible: !isInstalled, isEnabled: !isInstalled && isSelectionEnabled)
    }

    static func consentMessage(modelName: String, approximateBytes: Int64) -> String {
        String(
            format: NSLocalizedString("settings.fluid_audio.download_message", comment: ""),
            modelName,
            sizeLabel(approximateBytes)
        )
    }

    static func downloadSection(for modelSet: ModelSet?) -> DownloadSection? {
        switch modelSet {
        case .onDeviceASR, .whisperCppASR, .fluidAudioASR:
            return .transcription
        case .diarization, .sherpaOnnxDiarization, .vad, .fluidAudioDiarization:
            return .diarization
        case .liveTranscriptionASR, .fluidAudioUnifiedStreaming:
            return .live
        case nil:
            return nil
        }
    }
}
