import KurnCore
import Testing
@testable import Kurn

struct FluidAudioPipelineSelectionTests {
    @Test func legacyFluidAudioFingerprintIsUnchanged() {
        #expect(FluidAudioPipelineSelection.checkpointProviderID(
            engine: .fluidAudioParakeet, provider: .groq, whisperCppModel: .default, fluidAudioASRModel: .parakeetV3
        ) == nil)
        #expect(FluidAudioPipelineSelection.checkpointProviderID(
            engine: .appleSpeech, provider: .groq, whisperCppModel: .default, fluidAudioASRModel: .nemotronUnified
        ) == nil)
    }

    @Test(arguments: FluidAudioASRModel.allCases)
    func optionalModelIdentityCannotResumeAsAnotherVariant(model: FluidAudioASRModel) {
        let identity = FluidAudioPipelineSelection.checkpointProviderID(
            engine: .fluidAudioParakeet, provider: .groq, whisperCppModel: .default, fluidAudioASRModel: model
        )
        #expect(identity == model.checkpointProviderID)
        if model != .parakeetV3 { #expect(identity == "fluidaudio:\(model.rawValue)") }
    }

    @Test func onlySelectedModelFamiliesAreRequested() {
        var config = PipelineConfiguration()
        config.transcription = .fluidAudioParakeet
        config.fluidAudioASRModel = .nemotronUnified
        config.fluidAudioASRConsented = true
        config.fluidAudioDiarizationModel = .nemotron3
        config.diarizationConsented = true
        let sets = FluidAudioPipelineSelection.requiredModelSets(for: config)
        #expect(sets == [.fluidAudioASR(.nemotronUnified), .fluidAudioDiarization(.nemotron3)])
        config.languageDetection = .fluidAudioLID
        config.vad = .fluidAudio
        let expanded = FluidAudioPipelineSelection.requiredModelSets(for: config)
        #expect(expanded == [.fluidAudioASR(.nemotronUnified), .onDeviceASR, .vad, .fluidAudioDiarization(.nemotron3)])
        config.diarizationConsented = false
        #expect(!FluidAudioPipelineSelection.requiredModelSets(for: config).contains(.fluidAudioDiarization(.nemotron3)))
    }

    @Test(arguments: FluidAudioASRModel.allCases)
    func localOnlyLoadersDoNotDependOnTheTransferPolicy(model: FluidAudioASRModel) {
        var config = PipelineConfiguration()
        config.transcription = .fluidAudioParakeet
        config.fluidAudioASRModel = model
        config.fluidAudioASRConsented = true
        config.diarizationConsented = true
        config.fluidAudioDiarizationModel = .nemotron3
        config.languageDetection = .fluidAudioLID
        #expect(FluidAudioPipelineSelection.runtimeNetworkModelSets(for: config).isEmpty)
        config.vad = .fluidAudio
        #expect(FluidAudioPipelineSelection.runtimeNetworkModelSets(for: config) == [.vad])
    }

    @Test func otherEngineIdentitiesKeepTheirExistingMeaning() {
        #expect(FluidAudioPipelineSelection.checkpointProviderID(
            engine: .whisperAPI, provider: .groq, whisperCppModel: .default, fluidAudioASRModel: .nemotronUnified
        ) == "groq")
        #expect(FluidAudioPipelineSelection.checkpointProviderID(
            engine: .whisperCpp, provider: .groq, whisperCppModel: .default, fluidAudioASRModel: .nemotronUnified
        ) == "whispercpp:\(WhisperCppModel.default.rawValue)")
    }

    @Test func newModelsNeedTheirOwnConsentAndRejectUnsupportedLanguages() throws {
        var config = PipelineConfiguration()
        config.transcription = .fluidAudioParakeet
        config.fluidAudioASRModel = .bark3
        #expect(throws: AppError.self) { try FluidAudioPipelineSelection.validateASR(config: config, language: .english) }
        config.fluidAudioASRConsented = true
        #expect(throws: AppError.self) { try FluidAudioPipelineSelection.validateASR(config: config, language: .portuguese) }
        #expect(throws: AppError.self) { try FluidAudioPipelineSelection.validateASR(config: config, language: .autoDetect) }
        try FluidAudioPipelineSelection.validateASR(config: config, language: .english)
        config.fluidAudioASRModel = .nemotronUnified
        try FluidAudioPipelineSelection.validateASR(config: config, language: .portuguese)
        try FluidAudioPipelineSelection.validateASR(config: config, language: .autoDetect)
    }

    @Test func otherEnginesDoNotInheritAnUnusedModelRestriction() throws {
        var config = PipelineConfiguration()
        config.fluidAudioASRModel = .bark3
        for engine in [TranscriptionEngine.appleSpeech, .whisperAPI, .whisperCpp] {
            config.transcription = engine
            try FluidAudioPipelineSelection.validateASR(config: config, language: .portuguese)
        }
    }
}
