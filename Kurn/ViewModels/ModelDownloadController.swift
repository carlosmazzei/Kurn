//
//  ModelDownloadController.swift
//  Kurn
//
//  Owns the FluidAudio model-download machinery that Settings drives: which set
//  is currently downloading, the per-set consent dialogs, the engine choices
//  waiting on a successful download, and the list of what's installed on disk.
//
//  This used to live as a dozen `@State` properties on `SettingsView`, which was
//  fine while Settings was one screen. It no longer is: Transcription, Recording
//  and Storage are separate destinations that all read `downloadingModel` and all
//  can trigger a download, so the state has to outlive any one of them. Settings
//  creates it and puts it in the environment; each screen reads it from there.
//
//  `AppSettings` is passed per call rather than held, so the controller can be
//  constructed without one (a `@State` initializer can't reach the environment).
//

import Foundation

@MainActor
@Observable
final class ModelDownloadController {

    /// Which FluidAudio model set is currently downloading (`nil` when idle), so
    /// toggles/pickers can't be re-triggered mid-download and the matching
    /// section can surface a progress indicator.
    var downloadingModel: ModelSet?

    /// Downloaded model entries, refreshed when Storage appears and after any
    /// download or deletion.
    var installedModels: [ModelStore.InstalledModel] = []

    /// Model entry awaiting a delete confirmation, if any.
    var pendingModelDeletion: ModelStore.InstalledModel?

    /// Surfaced only if a consented download actually fails — the consent flags
    /// themselves are set after success, so a failure leaves the feature off and
    /// the consent dialog available to retry.
    var error: AppError?

    // MARK: - Consent dialogs

    var showingASRConsent = false
    var showingBatchASRConsent = false
    var showingDiarizationConsent = false
    var showingVADConsent = false

    // MARK: - Choices awaiting a download

    /// Engine choices awaiting a successful on-device-ASR model download before
    /// they're applied (both the transcription and language-detection pickers
    /// can require that model).
    var pendingTranscriptionEngine: TranscriptionEngine?
    var pendingLanguageDetectionEngine: LanguageDetectionEngine?
    var pendingDiarizationEngine: DiarizationEngine?
    var pendingVADEngine: VADEngine?

    /// True while any set is downloading. Controls across every Settings screen
    /// disable on this so two screens can't start competing downloads.
    var isDownloading: Bool { downloadingModel != nil }

    // MARK: - Engine selection (consent gates)

    /// Apply a transcription-engine choice, intercepting the FluidAudio engine
    /// to trigger a one-time model download (and deferring the change until it
    /// succeeds). Whisper without a configured provider is ignored (the row is
    /// disabled); `transcriptionProviders` is passed in because it depends on
    /// Keychain state the view tracks via its key revision.
    func selectTranscriptionEngine(
        _ engine: TranscriptionEngine,
        settings: AppSettings,
        transcriptionProviders: [AIProvider]
    ) {
        if engine == .whisperAPI {
            guard let first = transcriptionProviders.first else { return }
            // Point the transcription provider at a configured, capable provider
            // if the stored one is no longer valid.
            if !transcriptionProviders.contains(where: { $0.id == settings.transcriptionProviderID }) {
                settings.transcriptionProviderID = first.id
            }
        }
        if engine.requiredModelSet == .onDeviceASR && !settings.fluidAudioBatchASRModelsConsented {
            pendingTranscriptionEngine = engine
            showingBatchASRConsent = true
        } else {
            settings.transcriptionEngine = engine
        }
    }

    /// Apply a language-detection choice, intercepting the FluidAudio detector
    /// to trigger the same one-time on-device-ASR model download.
    func selectLanguageDetectionEngine(_ engine: LanguageDetectionEngine, settings: AppSettings) {
        if engine.requiredModelSet == .onDeviceASR && !settings.fluidAudioBatchASRModelsConsented {
            pendingLanguageDetectionEngine = engine
            showingBatchASRConsent = true
        } else {
            settings.languageDetectionEngine = engine
        }
    }

    func selectDiarizationEngine(_ engine: DiarizationEngine, settings: AppSettings) {
        if engine == .fluidAudio && !settings.fluidAudioDiarizationModelsConsented {
            pendingDiarizationEngine = engine
            showingDiarizationConsent = true
        } else {
            settings.diarizationEngine = engine
        }
    }

    /// Apply a VAD choice, intercepting the FluidAudio engine to trigger the
    /// one-time Silero VAD model download.
    func selectVADEngine(_ engine: VADEngine, settings: AppSettings) {
        if engine.requiredModelSet == .vad && !settings.fluidAudioVADModelsConsented {
            pendingVADEngine = engine
            showingVADConsent = true
        } else {
            settings.vadEngine = engine
        }
    }

    func setLiveTranscriptionEnabled(_ enabled: Bool, settings: AppSettings) {
        if enabled && !settings.fluidAudioASRModelsConsented {
            showingASRConsent = true
        } else {
            settings.liveTranscriptionEnabled = enabled
        }
    }

    // MARK: - Confirmed downloads

    func confirmLiveTranscriptionASR(settings: AppSettings) {
        download(.liveTranscriptionASR, recordingAs: .liveTranscription) {
            settings.fluidAudioASRModelsConsented = true
            settings.liveTranscriptionEnabled = true
        }
    }

    func confirmBatchASR(settings: AppSettings) {
        download(.onDeviceASR, recordingAs: .onDeviceLanguage) { [self] in
            settings.fluidAudioBatchASRModelsConsented = true
            // Apply whichever picker requested the download.
            if let engine = pendingTranscriptionEngine {
                settings.transcriptionEngine = engine
            }
            if let engine = pendingLanguageDetectionEngine {
                settings.languageDetectionEngine = engine
            }
        } cleanup: { [self] in
            pendingTranscriptionEngine = nil
            pendingLanguageDetectionEngine = nil
        }
    }

    func cancelBatchASR() {
        pendingTranscriptionEngine = nil
        pendingLanguageDetectionEngine = nil
    }

    func confirmDiarization(settings: AppSettings) {
        guard let engine = pendingDiarizationEngine else { return }
        pendingDiarizationEngine = nil
        download(.diarization, recordingAs: .diarization) {
            settings.fluidAudioDiarizationModelsConsented = true
            settings.diarizationEngine = engine
        }
    }

    func cancelDiarization() {
        pendingDiarizationEngine = nil
    }

    func confirmVAD(settings: AppSettings) {
        guard let engine = pendingVADEngine else { return }
        pendingVADEngine = nil
        download(.vad, recordingAs: .vad) {
            settings.fluidAudioVADModelsConsented = true
            settings.vadEngine = engine
        }
    }

    func cancelVAD() {
        pendingVADEngine = nil
    }

    /// The shared download body: mark the set as in flight, keep a finite
    /// background window so the download isn't aborted the moment Settings
    /// leaves the foreground, then apply `onSuccess` only if it actually landed.
    private func download(
        _ set: ModelSet,
        recordingAs group: ModelStore.ModelGroup,
        onSuccess: @escaping @MainActor () -> Void,
        cleanup: @escaping @MainActor () -> Void = {}
    ) {
        downloadingModel = set
        Task {
            let background = BackgroundActivity()
            background.begin(name: "ai.kurn.modelDownload")
            defer { background.end() }
            do {
                let before = ModelStore.snapshot()
                try await ModelDownloadConsent.download(set)
                ModelStore.recordDownload(for: group, before: before)
                onSuccess()
            } catch let appError as AppError {
                self.error = appError
            } catch {
                self.error = .modelDownloadFailed(error.localizedDescription)
            }
            cleanup()
            downloadingModel = nil
            refreshInstalledModels()
        }
    }

    // MARK: - Installed models

    /// Recompute installed model entries off the main thread.
    func refreshInstalledModels() {
        Task { @MainActor in
            installedModels = await Task.detached {
                ModelStore.installedModels()
            }.value
        }
    }

    /// Delete a model entry from disk and turn off any feature that uses it so
    /// the UI reflects the removal and it can be re-downloaded later.
    func deleteModel(_ model: ModelStore.InstalledModel, settings: AppSettings) {
        ModelStore.delete(model)
        guard let group = model.group else {
            pendingModelDeletion = nil
            refreshInstalledModels()
            return
        }
        switch group {
        case .liveTranscription:
            settings.liveTranscriptionEnabled = false
            settings.fluidAudioASRModelsConsented = false
        case .onDeviceLanguage:
            settings.fluidAudioBatchASRModelsConsented = false
            // Turn off the engines that depend on the multilingual on-device
            // model so the UI doesn't point at a now-missing model.
            if settings.transcriptionEngine == .fluidAudioParakeet {
                settings.transcriptionEngine = .appleSpeech
            }
            if settings.languageDetectionEngine == .fluidAudioLID {
                settings.languageDetectionEngine = .byTranscriber
            }
        case .diarization:
            settings.fluidAudioDiarizationModelsConsented = false
            settings.diarizationEngine = .heuristic
        case .vad:
            settings.fluidAudioVADModelsConsented = false
            settings.vadEngine = .energyThreshold
        }
        pendingModelDeletion = nil
        refreshInstalledModels()
    }
}
