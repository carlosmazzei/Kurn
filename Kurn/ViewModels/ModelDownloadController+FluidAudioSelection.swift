import Foundation
import KurnCore

extension ModelDownloadController {
    var pendingFluidAudioModelName: String { pendingFluidAudioSelection?.displayName ?? "" }
    var pendingFluidAudioModelBytes: Int64 { pendingFluidAudioSelection?.approximateBytes ?? 0 }

    func selectFluidAudioASRModel(_ model: FluidAudioASRModel, settings: AppSettings) {
        requestFluidAudioSelection(.asr(model, selectEngine: false), settings: settings)
    }

    func selectFluidAudioDiarizationModel(_ model: FluidAudioDiarizationModel, settings: AppSettings) {
        requestFluidAudioSelection(.diarization(model, selectEngine: false), settings: settings)
    }

    func selectFluidAudioLiveModel(_ model: FluidAudioLiveModel, settings: AppSettings) {
        requestFluidAudioSelection(.live(model, enable: false), settings: settings)
    }

    func confirmFluidAudioModel(settings: AppSettings) {
        guard !isDownloading, let selection = pendingFluidAudioSelection,
              selection.modelSet.isFluidAudioVariant else { return }
        guard validateFluidAudioSelection(selection, settings: settings) else {
            cancelFluidAudioModel()
            return
        }
        showingFluidAudioModelConsent = false
        download(selection.modelSet, recordingAs: selection.group, policy: settings.largeTransferPolicy) { [self] in
            guard validateFluidAudioSelection(selection, settings: settings) else { return }
            selection.apply(settings: settings)
        } cleanup: { [self] in
            pendingFluidAudioSelection = nil
        }
    }

    func cancelFluidAudioModel() {
        guard let selection = pendingFluidAudioSelection else { return }
        if downloadingModel == selection.modelSet { cancelDownload() }
        switch selection.modelSet {
        case .onDeviceASR:
            showingBatchASRConsent = false
            pendingTranscriptionEngine = nil
            pendingLanguageDetectionEngine = nil
        case .diarization:
            showingDiarizationConsent = false
            pendingDiarizationEngine = nil
        case .liveTranscriptionASR:
            showingASRConsent = false
        default:
            break
        }
        showingFluidAudioModelConsent = false
        pendingFluidAudioSelection = nil
    }

    func interceptFluidAudioTranscription(_ engine: TranscriptionEngine, settings: AppSettings) -> Bool {
        guard engine == .fluidAudioParakeet else { return false }
        requestFluidAudioSelection(.asr(settings.fluidAudioASRModel, selectEngine: true), settings: settings)
        return true
    }

    func interceptFluidAudioDiarization(_ engine: DiarizationEngine, settings: AppSettings) -> Bool {
        guard engine == .fluidAudio else { return false }
        requestFluidAudioSelection(.diarization(settings.fluidAudioDiarizationModel, selectEngine: true), settings: settings)
        return true
    }

    func interceptFluidAudioLive(_ enabled: Bool, settings: AppSettings) -> Bool {
        guard enabled else { return false }
        requestFluidAudioSelection(.live(settings.fluidAudioLiveModel, enable: true), settings: settings)
        return true
    }

    @discardableResult
    func applyPendingDefaultFluidAudioSelection(for set: ModelSet, settings: AppSettings) -> Bool {
        guard let selection = pendingFluidAudioSelection, selection.modelSet == set else { return false }
        selection.apply(settings: settings)
        return true
    }

    func clearPendingFluidAudioSelection(for set: ModelSet) {
        if pendingFluidAudioSelection?.modelSet == set { pendingFluidAudioSelection = nil }
    }

    func validatePendingFluidAudioSelection(for set: ModelSet, settings: AppSettings) -> Bool {
        guard let selection = pendingFluidAudioSelection, selection.modelSet == set else { return true }
        return validateFluidAudioSelection(selection, settings: settings)
    }

    private func requestFluidAudioSelection(_ selection: FluidAudioModelSelection, settings: AppSettings) {
        guard !isDownloading else { return }
        guard validateFluidAudioSelection(selection, settings: settings) else {
            cancelFluidAudioModel()
            return
        }
        cancelFluidAudioModel()
        error = nil
        if selection.isInstalled(using: self) &&
            (selection.modelSet.isFluidAudioVariant || selection.hasLegacyConsent(settings: settings)) {
            selection.apply(settings: settings)
            return
        }
        pendingFluidAudioSelection = selection
        switch selection.modelSet {
        case .onDeviceASR:
            if case .asr(_, true) = selection { pendingTranscriptionEngine = .fluidAudioParakeet }
            showingBatchASRConsent = true
        case .diarization:
            if case .diarization(_, true) = selection {
                pendingDiarizationEngine = .fluidAudio
            } else {
                pendingDiarizationEngine = settings.diarizationEngine
            }
            showingDiarizationConsent = true
        case .liveTranscriptionASR:
            showingASRConsent = true
        default:
            showingFluidAudioModelConsent = true
        }
    }

    private func validateFluidAudioSelection(_ selection: FluidAudioModelSelection, settings: AppSettings) -> Bool {
        if case .asr(let model, _) = selection, !model.supports(settings.defaultLanguage) {
            error = .transcriptionLanguageUnsupported(settings.defaultLanguage, .fluidAudioParakeet)
            return false
        }
        return true
    }
}
