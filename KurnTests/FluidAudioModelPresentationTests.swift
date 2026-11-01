import Foundation
import KurnCore
import Testing
@testable import Kurn

struct FluidAudioModelPresentationTests {
    @Test(arguments: FluidAudioASRModel.allCases)
    func asrLabelsIncludeProperNameAndApproximateSize(model: FluidAudioASRModel) {
        let label = FluidAudioModelPresentation.modelLabel(name: model.displayName, approximateBytes: model.approximateBytes)
        #expect(label.contains(model.displayName))
        #expect(label.contains(FluidAudioModelPresentation.sizeLabel(model.approximateBytes)))
        #expect(!label.contains("settings.fluid_audio."))
    }

    @Test(arguments: FluidAudioDiarizationModel.allCases)
    func diarizationLabelsIncludeProperNameAndApproximateSize(model: FluidAudioDiarizationModel) {
        let label = FluidAudioModelPresentation.modelLabel(name: model.displayName, approximateBytes: model.approximateBytes)
        #expect(label.contains(model.displayName))
        #expect(label.contains(FluidAudioModelPresentation.sizeLabel(model.approximateBytes)))
    }

    @Test func sizeUsesFileByteFormatting() {
        #expect(FluidAudioModelPresentation.sizeLabel(1_200_000_000) == ByteCountFormatter.string(
            fromByteCount: 1_200_000_000,
            countStyle: .file
        ))
    }

    @Test func automaticLiveLabelLocalizesTheModeAndPreservesModelNames() {
        let label = FluidAudioModelPresentation.liveModelLabel(.automatic)
        #expect(label == String(
            format: NSLocalizedString("settings.fluid_audio.live_automatic", comment: ""),
            FluidAudioLiveModel.automatic.displayName
        ))
        #expect(label.contains(FluidAudioLiveModel.automatic.displayName))
        #expect(label != FluidAudioLiveModel.automatic.displayName)
    }

    @Test func unifiedLiveLabelIncludesItsOwnDownloadSize() {
        let label = FluidAudioModelPresentation.liveModelLabel(.nemotronUnified)
        #expect(label.contains(FluidAudioLiveModel.nemotronUnified.displayName))
        #expect(label.contains(FluidAudioModelPresentation.sizeLabel(FluidAudioASRModel.nemotronUnified.approximateBytes)))
    }

    @Test(arguments: FluidAudioSegmentationBatchSize.allCases)
    func onlyRecommendedBatchSizeGetsAnAnnotation(batchSize: FluidAudioSegmentationBatchSize) {
        let label = FluidAudioModelPresentation.batchSizeLabel(batchSize)
        #expect(label.contains(String(batchSize.rawValue)))
        #expect((label != String(batchSize.rawValue)) == (batchSize == .recommended))
    }

    @Test func presentingBatchSizesDoesNotChangeThePreservedDefault() {
        #expect(FluidAudioSegmentationBatchSize.default == .maximum)
        #expect(FluidAudioSegmentationBatchSize.default.rawValue == 32)
        #expect(FluidAudioSegmentationBatchSize.recommended == .balanced)
        #expect(FluidAudioModelPresentation.batchSizeLabel(.default) == "32")
    }

    @Test(arguments: FluidAudioASRModel.allCases, MeetingLanguage.allCases)
    func availabilityRespectsLanguageAndTheGlobalDownloadLock(model: FluidAudioASRModel, language: MeetingLanguage) {
        #expect(FluidAudioModelPresentation.canSelectASRModel(model, language: language, isDownloading: false) == model.supports(language))
        #expect(!FluidAudioModelPresentation.canSelectASRModel(model, language: language, isDownloading: true))
    }

    @Test(arguments: [FluidAudioASRModel.bark3, .bark3Clean, .phonon2, .nemotronTranscribeLite])
    func selectingEnglishUnlocksEnglishOnlyModels(model: FluidAudioASRModel) {
        #expect(!FluidAudioModelPresentation.canSelectASRModel(model, language: .autoDetect, isDownloading: false))
        #expect(!FluidAudioModelPresentation.canSelectASRModel(model, language: .portuguese, isDownloading: false))
        #expect(FluidAudioModelPresentation.canSelectASRModel(model, language: .english, isDownloading: false))
    }

    @Test func unifiedSupportsAutoDetectAndPortuguese() {
        #expect(FluidAudioModelPresentation.canSelectASRModel(.nemotronUnified, language: .autoDetect, isDownloading: false))
        #expect(FluidAudioModelPresentation.canSelectASRModel(.nemotronUnified, language: .portuguese, isDownloading: false))
    }

    @Test(arguments: [Int64(190_000_000), 1_200_000_000, 1_400_000_000])
    func consentNamesTheSpecificModelAndDownloadSize(bytes: Int64) {
        let name = "Nemotron Unified 0.6B"
        let message = FluidAudioModelPresentation.consentMessage(modelName: name, approximateBytes: bytes)
        #expect(message.contains(name))
        #expect(message.contains(FluidAudioModelPresentation.sizeLabel(bytes)))
        #expect(!message.contains("settings.fluid_audio."))
        #expect(!message.contains("%@"))
    }

    @Test(arguments: [ModelSet.onDeviceASR, .whisperCppASR(.base), .fluidAudioASR(.bark3), .fluidAudioASR(.nemotronUnified)])
    func transcriptionProgressStaysInTheRecognitionSection(modelSet: ModelSet) {
        #expect(FluidAudioModelPresentation.downloadSection(for: modelSet) == .transcription)
    }

    @Test(arguments: [ModelSet.diarization, .sherpaOnnxDiarization, .vad, .fluidAudioDiarization(.nemotron3)])
    func diarizationAndVADProgressStaysInThePipelineSection(modelSet: ModelSet) {
        #expect(FluidAudioModelPresentation.downloadSection(for: modelSet) == .diarization)
    }

    @Test(arguments: [ModelSet.liveTranscriptionASR, .fluidAudioUnifiedStreaming])
    func legacyAndUnifiedLiveProgressStaysInRecordingSettings(modelSet: ModelSet) {
        #expect(FluidAudioModelPresentation.downloadSection(for: modelSet) == .live)
    }

    @Test func noDownloadMeansNoProgressSection() {
        #expect(FluidAudioModelPresentation.downloadSection(for: nil) == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func selectedModelDownloadIsVisibleOnlyWhenMissing(isInstalled: Bool, isSelectionEnabled: Bool) {
        let state = FluidAudioModelPresentation.downloadActionState(
            isInstalled: isInstalled,
            isSelectionEnabled: isSelectionEnabled
        )
        #expect(state.isVisible == !isInstalled)
        #expect(state.isEnabled == (!isInstalled && isSelectionEnabled))
    }

    @Test(arguments: FluidAudioASRModel.allCases, MeetingLanguage.allCases)
    func missingASRDownloadRespectsLanguageAndGlobalDownloadLock(model: FluidAudioASRModel, language: MeetingLanguage) {
        let idleState = FluidAudioModelPresentation.downloadActionState(
            isInstalled: false,
            isSelectionEnabled: FluidAudioModelPresentation.canSelectASRModel(model, language: language, isDownloading: false)
        )
        let downloadingState = FluidAudioModelPresentation.downloadActionState(
            isInstalled: false,
            isSelectionEnabled: FluidAudioModelPresentation.canSelectASRModel(model, language: language, isDownloading: true)
        )
        #expect(idleState.isVisible)
        #expect(idleState.isEnabled == model.supports(language))
        #expect(downloadingState.isVisible)
        #expect(!downloadingState.isEnabled)
    }

    @Test(arguments: FluidAudioLiveModel.allCases, MeetingLanguage.allCases)
    func liveEligibilityPreservesAutomaticAndGatesUnified(model: FluidAudioLiveModel, language: MeetingLanguage) {
        let eligible = FluidAudioModelPresentation.canSelectLiveModel(model, language: language, isDownloading: false)
        #expect(eligible == (model == .automatic || model.supports(language)))
        #expect(!FluidAudioModelPresentation.canSelectLiveModel(model, language: language, isDownloading: true))
    }

    @Test(arguments: [MeetingLanguage.chinese, .japanese, .korean])
    func incompatibleUnifiedLiveDownloadStaysVisibleButDisabled(language: MeetingLanguage) {
        let state = FluidAudioModelPresentation.downloadActionState(
            isInstalled: false,
            isSelectionEnabled: FluidAudioModelPresentation.canSelectLiveModel(.nemotronUnified, language: language, isDownloading: false)
        )
        #expect(state.isVisible)
        #expect(!state.isEnabled)
        #expect(FluidAudioModelPresentation.canSelectLiveModel(.automatic, language: language, isDownloading: false))
    }

    @Test(arguments: FluidAudioLiveModel.allCases, [false, true])
    func liveInstallationUsesOnlyTheSelectedStrictPredicate(model: FluidAudioLiveModel, installed: Bool) {
        var probes: [FluidAudioLiveModel] = []
        let result = FluidAudioModelPresentation.isLiveModelInstalled(
            model,
            automaticInstalled: {
                probes.append(.automatic)
                return model == .automatic ? installed : !installed
            },
            unifiedInstalled: {
                probes.append(.nemotronUnified)
                return model == .nemotronUnified ? installed : !installed
            }
        )
        #expect(result == installed)
        #expect(probes == [model])
    }

    @Test(arguments: [MeetingLanguage.chinese, .japanese, .korean])
    func incompatibleUnifiedGuidanceNamesTheLanguageAndModel(language: MeetingLanguage) {
        let guidance = FluidAudioModelPresentation.liveLanguageGuidance(.nemotronUnified, language: language)
        #expect(guidance?.contains(language.displayName) == true)
        #expect(guidance?.contains(FluidAudioLiveModel.nemotronUnified.displayName) == true)
        #expect(guidance?.contains("%@") == false)
    }

    @Test(arguments: [MeetingLanguage.autoDetect, .english, .portuguese])
    func supportedUnifiedLanguagesNeedNoWarning(language: MeetingLanguage) {
        #expect(FluidAudioModelPresentation.liveLanguageGuidance(.nemotronUnified, language: language) == nil)
        #expect(FluidAudioModelPresentation.canSelectLiveModel(.nemotronUnified, language: language, isDownloading: false))
    }

    @Test func legacyAutomaticDoesNotAcquireANewLanguageRestriction() {
        #expect(!FluidAudioLiveModel.automatic.supports(.korean))
        #expect(FluidAudioModelPresentation.canSelectLiveModel(.automatic, language: .korean, isDownloading: false))
        #expect(FluidAudioModelPresentation.liveLanguageGuidance(.automatic, language: .korean) == nil)
    }
}
