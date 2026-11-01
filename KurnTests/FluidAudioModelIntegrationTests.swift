import Foundation
import KurnCore
import Testing
@testable import Kurn

@MainActor
@Suite("FluidAudio model selection and storage", .serialized)
struct FluidAudioModelIntegrationTests {
    @Test func newSettingsKeepLegacyDefaultsAndConsentOff() async throws {
        try await withFluidAudioDownloadHarness { harness in
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(harness.settings.fluidAudioDiarizationModel == .pyannote)
            #expect(harness.settings.fluidAudioLiveModel == .automatic)
            #expect(harness.settings.defaultLanguage == .autoDetect)
            #expect(harness.settings.fluidAudioASRModelConsents.isEmpty)
            #expect(!harness.settings.fluidAudioNemotronModelsConsented)
            #expect(!harness.settings.fluidAudioUnifiedStreamingConsented)
            #expect(!harness.settings.fluidAudioBatchASRModelsConsented)
            #expect(!harness.settings.fluidAudioDiarizationModelsConsented)
            #expect(!harness.settings.fluidAudioASRModelsConsented)
            #expect(!harness.settings.selectedFluidAudioASRModelsConsented)
            #expect(!harness.settings.selectedFluidDiarizationConsented)
            #expect(!harness.settings.selectedFluidAudioLiveModelsConsented)
        }
    }

    @Test func appMappingsKeepDefaultAndLIDIdentities() {
        #expect(FluidAudioASRModel.parakeetV3.requiredModelSet == .onDeviceASR)
        #expect(FluidAudioDiarizationModel.pyannote.requiredModelSet == .diarization)
        #expect(FluidAudioLiveModel.automatic.requiredModelSet == .liveTranscriptionASR)
        #expect(FluidAudioLiveModel.nemotronUnified.requiredModelSet == .fluidAudioUnifiedStreaming)
        #expect(FluidAudioDiarizationModel.nemotron3.requiredModelSet == .fluidAudioDiarization(.nemotron3))
        #expect(LanguageDetectionEngine.fluidAudioLID.requiredModelSet == .onDeviceASR)
        #expect(TranscriptionEngine.fluidAudioParakeet.requiredModelSet(whisperCppModel: .small) == .onDeviceASR)
        #expect(FluidAudioModelSelection.asr(.parakeetV3, selectEngine: false).group == .onDeviceLanguage)
        #expect(FluidAudioModelSelection.diarization(.pyannote, selectEngine: false).group == .diarization)
        #expect(FluidAudioModelSelection.live(.automatic, enable: false).group == .liveTranscription)
        #expect(FluidAudioModelSelection.diarization(.nemotron3, selectEngine: false).group == .nemotronDiarization)
        #expect(FluidAudioModelSelection.live(.nemotronUnified, enable: false).group == .fluidAudioASR)
        for model in FluidAudioASRModel.allCases where model != .parakeetV3 {
            #expect(FluidAudioModelSelection.asr(model, selectEngine: false).group == .fluidAudioASR)
            #expect(model.requiredModelSet == .fluidAudioASR(model))
            #expect(TranscriptionEngine.fluidAudioParakeet.requiredModelSet(
                whisperCppModel: .small, fluidAudioASRModel: model
            ) == .fluidAudioASR(model))
        }
    }

    @Test func modelSetInstallationQueriesNeverStartDownloads() {
        let sets = FluidAudioASRModel.allCases.map(\.requiredModelSet) + [
            FluidAudioDiarizationModel.nemotron3.requiredModelSet,
            FluidAudioLiveModel.nemotronUnified.requiredModelSet
        ]
        for set in sets { #expect(set.isInstalled == set.isInstalled) }
        #expect(!ModelSet.onDeviceASR.isFluidAudioVariant)
        #expect(!ModelSet.diarization.isFluidAudioVariant)
        #expect(!ModelSet.liveTranscriptionASR.isFluidAudioVariant)
        #expect(sets.filter(\.isFluidAudioVariant).count == sets.count - 1)
    }

    @Test(arguments: FluidAudioASRModel.allCases.filter { $0 != .parakeetV3 })
    func asrVariantsWaitForConfirmationAndCommitOnlyAfterSuccess(_ model: FluidAudioASRModel) async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.defaultLanguage = .english
            harness.settings.allowsExpensiveNetworkTransfers = true
            harness.controller.selectFluidAudioASRModel(model, settings: harness.settings)
            #expect(harness.controller.showingFluidAudioModelConsent)
            #expect(harness.controller.pendingFluidAudioModelName == model.displayName)
            #expect(harness.controller.pendingFluidAudioModelBytes == model.approximateBytes)
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(harness.script.calls.isEmpty)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            await harness.awaitDownloadSettled()
            #expect(harness.script.calls == [.init(set: .fluidAudioASR(model), policy: harness.settings.largeTransferPolicy)])
            #expect(harness.settings.fluidAudioASRModel == model)
            #expect(harness.settings.fluidAudioASRModelConsents == [model.rawValue])
            #expect(harness.settings.selectedFluidAudioASRModelsConsented)
            #expect(!harness.settings.fluidAudioBatchASRModelsConsented)
            #expect(!harness.settings.fluidAudioUnifiedStreamingConsented)
            #expect(harness.controller.pendingFluidAudioModelName.isEmpty)
            #expect(harness.controller.pendingFluidAudioModelBytes == 0)
            #expect(harness.controller.error == nil)
        }
    }

    @Test(arguments: FluidAudioASRModel.allCases.filter { $0 != .parakeetV3 })
    func alreadyInstalledASRChoiceRecordsOnlyThatConsentWithoutNetwork(_ model: FluidAudioASRModel) async throws {
        try await withFluidAudioDownloadHarness(installedASR: [model]) { harness in
            harness.settings.defaultLanguage = .english
            harness.controller.selectFluidAudioASRModel(model, settings: harness.settings)
            #expect(harness.settings.fluidAudioASRModel == model)
            #expect(harness.settings.fluidAudioASRModelConsents == [model.rawValue])
            #expect(!harness.settings.fluidAudioBatchASRModelsConsented)
            #expect(!harness.controller.showingFluidAudioModelConsent)
            #expect(harness.script.calls.isEmpty)
        }
    }

    @Test func installedDiarizationAndStreamingChoicesApplyWithoutNetwork() async throws {
        try await withFluidAudioDownloadHarness(
            installedDiarization: [.nemotron3], installedUnifiedStreaming: true
        ) { harness in
            harness.controller.selectFluidAudioDiarizationModel(.nemotron3, settings: harness.settings)
            harness.controller.selectFluidAudioLiveModel(.nemotronUnified, settings: harness.settings)
            #expect(harness.settings.fluidAudioDiarizationModel == .nemotron3)
            #expect(harness.settings.fluidAudioNemotronModelsConsented)
            #expect(harness.settings.selectedFluidDiarizationConsented)
            #expect(!harness.settings.fluidAudioDiarizationModelsConsented)
            #expect(harness.settings.fluidAudioLiveModel == .nemotronUnified)
            #expect(harness.settings.fluidAudioUnifiedStreamingConsented)
            #expect(harness.settings.selectedFluidAudioLiveModelsConsented)
            #expect(!harness.settings.fluidAudioASRModelsConsented)
            #expect(!harness.settings.liveTranscriptionEnabled)
            #expect(harness.script.calls.isEmpty)
        }
    }

    @Test func sharedUnifiedFolderDoesNotConflateBatchAndStreamingInstallation() async throws {
        try await withFluidAudioDownloadHarness(installedASR: [.nemotronUnified]) { harness in
            harness.controller.selectFluidAudioASRModel(.nemotronUnified, settings: harness.settings)
            #expect(harness.settings.selectedFluidAudioASRModelsConsented)
            harness.controller.selectFluidAudioLiveModel(.nemotronUnified, settings: harness.settings)
            #expect(harness.controller.showingFluidAudioModelConsent)
            #expect(harness.controller.pendingFluidAudioModelName == FluidAudioLiveModel.nemotronUnified.displayName)
            #expect(harness.controller.pendingFluidAudioModelBytes == FluidAudioASRModel.nemotronUnified.approximateBytes)
            #expect(harness.settings.fluidAudioLiveModel == .automatic)
            #expect(!harness.settings.fluidAudioUnifiedStreamingConsented)
            #expect(harness.script.calls.isEmpty)
            harness.controller.cancelFluidAudioModel()
            harness.settings.defaultLanguage = .english
            harness.controller.selectFluidAudioASRModel(.bark3, settings: harness.settings)
            #expect(harness.controller.showingFluidAudioModelConsent)
            #expect(harness.settings.fluidAudioASRModel == .nemotronUnified)
        }
    }

    @Test func cancelAndFailureKeepTheOldChoiceAndConsent() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.defaultLanguage = .english
            harness.controller.selectFluidAudioASRModel(.bark3, settings: harness.settings)
            harness.controller.cancelFluidAudioModel()
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            #expect(harness.script.calls.isEmpty)
            #expect(!harness.controller.showingFluidAudioModelConsent)
            harness.script.fail(with: AppError.networkPolicyRestricted)
            harness.controller.selectFluidAudioASRModel(.phonon2, settings: harness.settings)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(harness.settings.fluidAudioASRModelConsents.isEmpty)
            #expect(harness.controller.pendingFluidAudioSelection == nil)
            guard case .networkPolicyRestricted = harness.controller.error else {
                Issue.record("expected policy error")
                return
            }
        }
    }

    @Test(arguments: [MeetingLanguage.autoDetect, .portuguese, .japanese])
    func unsupportedASRLanguageNeverStartsNetworkEvenForInstalledModels(_ language: MeetingLanguage) async throws {
        try await withFluidAudioDownloadHarness(installedASR: [.bark3]) { harness in
            harness.settings.defaultLanguage = language
            harness.controller.selectFluidAudioASRModel(.bark3, settings: harness.settings)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            #expect(harness.settings.defaultLanguage == language)
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(!harness.controller.showingFluidAudioModelConsent)
            #expect(harness.script.calls.isEmpty)
            guard case .transcriptionLanguageUnsupported(let actual, .fluidAudioParakeet) = harness.controller.error else {
                Issue.record("expected unsupported language")
                return
            }
            #expect(actual == language)
        }
    }

    @Test func failedDiarizationAndLiveDownloadsDoNotChangeChoicesOrConsent() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.script.fail(with: AppError.modelDownloadFailed("fixture"))
            harness.controller.selectFluidAudioDiarizationModel(.nemotron3, settings: harness.settings)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioDiarizationModel == .pyannote)
            #expect(!harness.settings.fluidAudioNemotronModelsConsented)
            harness.controller.selectFluidAudioLiveModel(.nemotronUnified, settings: harness.settings)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioLiveModel == .automatic)
            #expect(!harness.settings.fluidAudioUnifiedStreamingConsented)
            #expect(!harness.settings.liveTranscriptionEnabled)
            #expect(harness.script.calls.map(\.set) == [.fluidAudioDiarization(.nemotron3), .fluidAudioUnifiedStreaming])
        }
    }

    @Test func invalidChoiceClearsAnEarlierPendingDownload() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.controller.selectFluidAudioASRModel(.nemotronUnified, settings: harness.settings)
            harness.controller.selectFluidAudioASRModel(.bark3, settings: harness.settings)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            #expect(harness.script.calls.isEmpty)
            #expect(harness.controller.pendingFluidAudioSelection == nil)
            #expect(!harness.controller.showingFluidAudioModelConsent)
        }
    }

    @Test func languageIsValidatedAgainBeforeConfirmedDownload() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.defaultLanguage = .english
            harness.controller.selectFluidAudioASRModel(.bark3Clean, settings: harness.settings)
            harness.settings.defaultLanguage = .autoDetect
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            #expect(harness.script.calls.isEmpty)
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(harness.controller.pendingFluidAudioSelection == nil)
        }
    }

    @Test func engineSelectionUsesTheSelectedASRVariantRatherThanV3Consent() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.defaultLanguage = .english
            harness.settings.transcriptionEngine = .appleSpeech
            harness.settings.fluidAudioASRModel = .phonon2
            harness.settings.fluidAudioBatchASRModelsConsented = true
            harness.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: harness.settings, transcriptionProviders: [])
            #expect(harness.settings.transcriptionEngine == .appleSpeech)
            #expect(harness.controller.showingFluidAudioModelConsent)
            #expect(!harness.controller.showingBatchASRConsent)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.transcriptionEngine == .fluidAudioParakeet)
            #expect(harness.script.calls.map(\.set) == [.fluidAudioASR(.phonon2)])
            #expect(harness.settings.fluidAudioASRModelConsents == [FluidAudioASRModel.phonon2.rawValue])
        }
    }

    @Test func selectedDiarizationAndLiveModelsGateTheirOwnDownloads() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.diarizationEngine = .heuristic
            harness.settings.fluidAudioDiarizationModel = .nemotron3
            harness.settings.fluidAudioDiarizationModelsConsented = true
            harness.controller.selectDiarizationEngine(.fluidAudio, settings: harness.settings)
            #expect(harness.settings.diarizationEngine == .heuristic)
            #expect(harness.controller.pendingFluidAudioModelName == FluidAudioDiarizationModel.nemotron3.displayName)
            #expect(harness.controller.pendingFluidAudioModelBytes == 190_000_000)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.diarizationEngine == .fluidAudio)
            #expect(harness.settings.fluidAudioNemotronModelsConsented)
            harness.settings.fluidAudioLiveModel = .nemotronUnified
            harness.settings.fluidAudioASRModelsConsented = true
            harness.controller.setLiveTranscriptionEnabled(true, settings: harness.settings)
            #expect(!harness.settings.liveTranscriptionEnabled)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.liveTranscriptionEnabled)
            #expect(harness.settings.fluidAudioUnifiedStreamingConsented)
            #expect(!harness.settings.fluidAudioASRModelConsents.contains(FluidAudioASRModel.nemotronUnified.rawValue))
            #expect(harness.script.calls.map(\.set) == [.fluidAudioDiarization(.nemotron3), .fluidAudioUnifiedStreaming])
        }
    }

    @Test func unsupportedSelectedASRAlsoBlocksEngineActivation() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.transcriptionEngine = .appleSpeech
            harness.settings.fluidAudioASRModel = .nemotronTranscribeLite
            harness.controller.selectTranscriptionEngine(.fluidAudioParakeet, settings: harness.settings, transcriptionProviders: [])
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            #expect(harness.settings.transcriptionEngine == .appleSpeech)
            #expect(harness.settings.defaultLanguage == .autoDetect)
            #expect(harness.script.calls.isEmpty)
            guard case .transcriptionLanguageUnsupported = harness.controller.error else {
                Issue.record("expected selected model language validation")
                return
            }
        }
    }

    @Test func missingModelsAskAgainDespitePersistedConsent() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioASRModelConsents = [FluidAudioASRModel.nemotronUnified.rawValue]
            harness.controller.selectFluidAudioASRModel(.nemotronUnified, settings: harness.settings)
            #expect(harness.controller.showingFluidAudioModelConsent)
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(harness.script.calls.isEmpty)
        }
    }

    @Test func cancellationRejectsLateSuccessAndConcurrentChoices() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioASRModelsConsented = true
            harness.script.returnSuccessAfterCancellation()
            harness.controller.selectFluidAudioLiveModel(.nemotronUnified, settings: harness.settings)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            await harness.awaitDownloadStarted()
            harness.controller.selectFluidAudioDiarizationModel(.nemotron3, settings: harness.settings)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            harness.controller.confirmLiveTranscriptionASR(settings: harness.settings)
            harness.controller.cancelFluidAudioModel()
            await harness.awaitDownloadSettled()
            #expect(harness.script.calls.map(\.set) == [.fluidAudioUnifiedStreaming])
            #expect(harness.settings.fluidAudioLiveModel == .automatic)
            #expect(harness.settings.fluidAudioDiarizationModel == .pyannote)
            #expect(!harness.settings.fluidAudioUnifiedStreamingConsented)
            #expect(harness.settings.fluidAudioASRModelsConsented)
            #expect(harness.settings.selectedFluidAudioLiveModelsConsented)
            #expect(!harness.settings.liveTranscriptionEnabled)
            #expect(harness.controller.error == nil)
        }
    }

    @Test func immediateCancellationNeverCallsTheDownloader() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.controller.selectFluidAudioLiveModel(.nemotronUnified, settings: harness.settings)
            harness.controller.confirmFluidAudioModel(settings: harness.settings)
            harness.controller.cancelDownload()
            await harness.awaitDownloadSettled()
            #expect(harness.script.calls.isEmpty)
            #expect(harness.settings.fluidAudioLiveModel == .automatic)
            #expect(!harness.settings.fluidAudioUnifiedStreamingConsented)
        }
    }

    @Test func defaultVariantSelectionRetainsLegacyDialogsAndDelayedCommit() async throws {
        try await withFluidAudioDownloadHarness { harness in
            harness.settings.fluidAudioASRModel = .nemotronUnified
            harness.controller.selectFluidAudioASRModel(.parakeetV3, settings: harness.settings)
            #expect(harness.controller.showingBatchASRConsent)
            #expect(harness.settings.fluidAudioASRModel == .nemotronUnified)
            harness.controller.confirmBatchASR(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioASRModel == .parakeetV3)
            #expect(harness.settings.fluidAudioBatchASRModelsConsented)
            harness.settings.fluidAudioDiarizationModel = .nemotron3
            harness.controller.selectFluidAudioDiarizationModel(.pyannote, settings: harness.settings)
            #expect(harness.controller.showingDiarizationConsent)
            harness.controller.confirmDiarization(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioDiarizationModel == .pyannote)
            harness.settings.fluidAudioLiveModel = .nemotronUnified
            harness.controller.selectFluidAudioLiveModel(.automatic, settings: harness.settings)
            #expect(harness.controller.showingASRConsent)
            harness.controller.confirmLiveTranscriptionASR(settings: harness.settings)
            await harness.awaitDownloadSettled()
            #expect(harness.settings.fluidAudioLiveModel == .automatic)
            #expect(!harness.settings.liveTranscriptionEnabled)
            #expect(harness.script.calls.map(\.set) == [.onDeviceASR, .diarization, .liveTranscriptionASR])
        }
    }
}
