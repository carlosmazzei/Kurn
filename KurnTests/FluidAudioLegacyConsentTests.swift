import Foundation
import KurnCore
import Testing
@testable import Kurn

extension FluidAudioModelIntegrationTests {
    @Test(arguments: [false, true])
    func legacyCachePresenceNeverGrantsInitialConsent(installed: Bool) async throws {
        try await withFluidAudioDownloadHarness(
            installedASR: installed ? [.parakeetV3] : [],
            installedDiarization: installed ? [.pyannote] : [],
            installedAutomaticLive: installed
        ) { harness in
            harness.controller.selectFluidAudioASRModel(.parakeetV3, settings: harness.settings)
            #expect(harness.controller.showingBatchASRConsent)
            #expect(!harness.settings.fluidAudioBatchASRModelsConsented)
            #expect(!harness.controller.showingFluidAudioModelConsent)
            harness.controller.cancelFluidAudioModel()
            harness.controller.selectFluidAudioDiarizationModel(.pyannote, settings: harness.settings)
            #expect(harness.controller.showingDiarizationConsent)
            #expect(!harness.settings.fluidAudioDiarizationModelsConsented)
            harness.controller.cancelFluidAudioModel()
            harness.controller.selectFluidAudioLiveModel(.automatic, settings: harness.settings)
            #expect(harness.controller.showingASRConsent)
            #expect(!harness.settings.fluidAudioASRModelsConsented)
            harness.controller.cancelFluidAudioModel()
            #expect(harness.controller.pendingFluidAudioSelection == nil)
            #expect(harness.script.calls.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func defaultEngineActivationAlwaysRequiresLegacyConsent(installed: Bool) async throws {
        try await withFluidAudioDownloadHarness(
            installedASR: installed ? [.parakeetV3] : [],
            installedDiarization: installed ? [.pyannote] : [],
            installedAutomaticLive: installed
        ) { harness in
            harness.settings.transcriptionEngine = .appleSpeech
            harness.settings.diarizationEngine = .heuristic
            harness.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: harness.settings, transcriptionProviders: [])
            #expect(harness.controller.pendingTranscriptionEngine == .fluidAudioParakeet)
            #expect(harness.controller.showingBatchASRConsent)
            #expect(harness.settings.transcriptionEngine == .appleSpeech)
            harness.controller.cancelBatchASR()
            harness.controller.selectDiarizationEngine(.fluidAudio, settings: harness.settings)
            #expect(harness.controller.pendingDiarizationEngine == .fluidAudio)
            #expect(harness.controller.showingDiarizationConsent)
            #expect(harness.settings.diarizationEngine == .heuristic)
            harness.controller.cancelDiarization()
            harness.controller.setLiveTranscriptionEnabled(true, settings: harness.settings)
            #expect(harness.controller.showingASRConsent)
            #expect(!harness.settings.liveTranscriptionEnabled)
            #expect(!harness.settings.fluidAudioBatchASRModelsConsented)
            #expect(!harness.settings.fluidAudioDiarizationModelsConsented)
            #expect(!harness.settings.fluidAudioASRModelsConsented)
            #expect(harness.script.calls.isEmpty)
        }
    }

    @Test func consentedButMissingLegacyModelsCanRepairTheCurrentSelection() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioBatchASRModelsConsented = true
            harness.settings.fluidAudioDiarizationModelsConsented = true
            harness.settings.fluidAudioASRModelsConsented = true
            harness.settings.transcriptionEngine = .appleSpeech
            harness.settings.diarizationEngine = .heuristic
            harness.controller.selectFluidAudioASRModel(.parakeetV3, settings: harness.settings)
            #expect(harness.controller.showingBatchASRConsent)
            #expect(harness.script.calls.isEmpty)
            harness.controller.confirmBatchASR(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(harness.settings.transcriptionEngine == .appleSpeech)
            harness.controller.selectFluidAudioDiarizationModel(.pyannote, settings: harness.settings)
            #expect(harness.controller.showingDiarizationConsent)
            harness.controller.confirmDiarization(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioDiarizationModel == .pyannote)
            #expect(harness.settings.diarizationEngine == .heuristic)
            harness.controller.selectFluidAudioLiveModel(.automatic, settings: harness.settings)
            #expect(harness.controller.showingASRConsent)
            harness.controller.confirmLiveTranscriptionASR(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioLiveModel == .automatic)
            #expect(!harness.settings.liveTranscriptionEnabled)
            #expect(harness.script.calls.map(\.set) == [.onDeviceASR, .diarization, .liveTranscriptionASR])
        }
    }

    @Test func consentedButMissingDefaultsAlsoGateEngineActivation() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioBatchASRModelsConsented = true
            harness.settings.fluidAudioDiarizationModelsConsented = true
            harness.settings.fluidAudioASRModelsConsented = true
            harness.settings.transcriptionEngine = .appleSpeech
            harness.settings.diarizationEngine = .heuristic
            harness.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: harness.settings, transcriptionProviders: [])
            #expect(harness.controller.showingBatchASRConsent)
            #expect(harness.controller.pendingTranscriptionEngine == .fluidAudioParakeet)
            #expect(harness.settings.transcriptionEngine == .appleSpeech)
            harness.controller.confirmBatchASR(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.transcriptionEngine == .fluidAudioParakeet)
            harness.controller.selectDiarizationEngine(.fluidAudio, settings: harness.settings)
            #expect(harness.controller.showingDiarizationConsent)
            #expect(harness.controller.pendingDiarizationEngine == .fluidAudio)
            #expect(harness.settings.diarizationEngine == .heuristic)
            harness.controller.confirmDiarization(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.diarizationEngine == .fluidAudio)
            harness.controller.setLiveTranscriptionEnabled(true, settings: harness.settings)
            #expect(harness.controller.showingASRConsent)
            #expect(!harness.settings.liveTranscriptionEnabled)
            harness.controller.confirmLiveTranscriptionASR(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.liveTranscriptionEnabled)
            #expect(harness.script.calls.map(\.set) == [.onDeviceASR, .diarization, .liveTranscriptionASR])
        }
    }

    @Test func completeConsentedDefaultsApplyWithoutDownloading() async throws {
        try await withFluidAudioDownloadHarness(
            installedASR: [.parakeetV3], installedDiarization: [.pyannote], installedAutomaticLive: true
        ) { harness in
            harness.settings.fluidAudioBatchASRModelsConsented = true
            harness.settings.fluidAudioDiarizationModelsConsented = true
            harness.settings.fluidAudioASRModelsConsented = true
            harness.settings.transcriptionEngine = .appleSpeech
            harness.settings.diarizationEngine = .heuristic
            harness.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: harness.settings, transcriptionProviders: [])
            harness.controller.selectDiarizationEngine(.fluidAudio, settings: harness.settings)
            harness.controller.setLiveTranscriptionEnabled(true, settings: harness.settings)
            #expect(harness.settings.transcriptionEngine == .fluidAudioParakeet)
            #expect(harness.settings.diarizationEngine == .fluidAudio)
            #expect(harness.settings.liveTranscriptionEnabled)
            #expect(!harness.controller.showingBatchASRConsent)
            #expect(!harness.controller.showingDiarizationConsent)
            #expect(!harness.controller.showingASRConsent)
            #expect(harness.script.calls.isEmpty)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func languageDetectionRequiresBothV3ConsentAndCompleteInstallation(installed: Bool, consented: Bool) async throws {
        try await withFluidAudioDownloadHarness(installedASR: installed ? [.parakeetV3] : []) { harness in
            harness.settings.fluidAudioBatchASRModelsConsented = consented
            harness.controller.selectLanguageDetectionEngine(.fluidAudioLID, settings: harness.settings)
            if installed && consented {
                #expect(harness.settings.languageDetectionEngine == .fluidAudioLID)
                #expect(!harness.controller.showingBatchASRConsent)
            } else {
                #expect(harness.settings.languageDetectionEngine == .byTranscriber)
                #expect(harness.controller.showingBatchASRConsent)
                #expect(harness.controller.pendingLanguageDetectionEngine == .fluidAudioLID)
            }
            #expect(harness.script.calls.isEmpty)
        }
    }

    @Test func repairingLIDStillUsesV3WithoutChangingTheSelectedBatchVariant() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioASRModel = .bark3
            harness.settings.fluidAudioBatchASRModelsConsented = true
            harness.controller.selectLanguageDetectionEngine(.fluidAudioLID, settings: harness.settings)
            #expect(harness.controller.showingBatchASRConsent)
            harness.controller.confirmBatchASR(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.languageDetectionEngine == .fluidAudioLID)
            #expect(harness.settings.fluidAudioASRModel == .bark3)
            #expect(harness.script.calls.map(\.set) == [.onDeviceASR])
        }
    }

    @Test(arguments: [false, true])
    func aLanguageChangeDuringEnglishASRDownloadPreventsApplyingTheChoice(activateEngine: Bool) async throws {
        try await withFluidAudioDownloadHarness { harness in
            let originalModel: FluidAudioASRModel = activateEngine ? .bark3 : .parakeetV3
            harness.settings.fluidAudioASRModel = originalModel
            harness.settings.defaultLanguage = .english
            harness.settings.transcriptionEngine = .appleSpeech
            harness.script.holdUntilReleased()
            if activateEngine {
                harness.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: harness.settings, transcriptionProviders: [])
            } else {
                harness.controller.selectFluidAudioASRModel(.bark3, settings: harness.settings)
            }
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            await harness.awaitDownloadStarted()
            harness.settings.defaultLanguage = .autoDetect
            harness.script.release()
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioASRModel == originalModel)
            #expect(harness.settings.transcriptionEngine == .appleSpeech)
            #expect(!harness.settings.fluidAudioASRModelConsents.contains(FluidAudioASRModel.bark3.rawValue))
            #expect(harness.settings.defaultLanguage == .autoDetect)
            #expect(harness.script.calls.map(\.set) == [.fluidAudioASR(.bark3)])
            #expect(harness.controller.pendingFluidAudioSelection == nil)
            guard case .transcriptionLanguageUnsupported(.autoDetect, .fluidAudioParakeet) = harness.controller.error else {
                Issue.record("Expected post-download language validation to reject the selection")
                return
            }
        }
    }

    @Test func defaultASRAlsoRevalidatesLanguageAfterDownloading() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioASRModel = .nemotronUnified
            harness.settings.defaultLanguage = .english
            harness.settings.transcriptionEngine = .appleSpeech
            harness.script.holdUntilReleased()
            harness.controller.selectFluidAudioASRModel(.parakeetV3, settings: harness.settings)
            harness.controller.confirmBatchASR(settings: harness.settings)
            await harness.awaitDownloadStarted()
            harness.settings.defaultLanguage = .japanese
            harness.script.release()
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioASRModel == .nemotronUnified)
            #expect(harness.settings.transcriptionEngine == .appleSpeech)
            #expect(!harness.settings.fluidAudioBatchASRModelsConsented)
            #expect(harness.controller.pendingFluidAudioSelection == nil)
            guard case .transcriptionLanguageUnsupported(.japanese, .fluidAudioParakeet) = harness.controller.error else {
                Issue.record("Expected default ASR post-download language validation")
                return
            }
        }
    }

    @Test func pendingAutomaticLiveSelectionCanBeClearedWithoutConsentOrNetwork() async throws {
        try await withFluidAudioDownloadHarness(installedAutomaticLive: true) { harness in
            harness.settings.fluidAudioLiveModel = .nemotronUnified
            harness.controller.selectFluidAudioLiveModel(.automatic, settings: harness.settings)
            #expect(harness.controller.showingASRConsent)
            harness.controller.clearPendingFluidAudioSelection(for: .liveTranscriptionASR)
            #expect(harness.controller.pendingFluidAudioSelection == nil)
            #expect(harness.settings.fluidAudioLiveModel == .nemotronUnified)
            #expect(!harness.settings.fluidAudioASRModelsConsented)
            #expect(harness.script.calls.isEmpty)
        }
    }
}
