import Testing
@testable import Kurn

struct PipelineEvaluationMatrixTests {
    @Test func emptyDiarizationFilterIncludesEveryEngine() {
        #expect(PipelineEvaluationMatrix.diarizationEngines(from: nil) == DiarizationEngine.allCases)
        #expect(PipelineEvaluationMatrix.diarizationEngines(from: "") == DiarizationEngine.allCases)
        #expect(PipelineEvaluationMatrix.diarizationEngines(from: "  ") == DiarizationEngine.allCases)
        #expect(PipelineEvaluationMatrix.diarizationEngines(from: "all") == DiarizationEngine.allCases)
    }

    @Test func diarizationFilterAcceptsCommaSeparatedRawValues() {
        let engines = PipelineEvaluationMatrix.diarizationEngines(from: " sherpaOnnx,HEURISTIC ")
        #expect(engines == [.heuristic, .sherpaOnnx])
    }

    @Test func essentialSherpaOnnxFilterBuildsOnlyFourConfigurations() {
        let all = PipelineEvaluationMatrix.build(
            whisperCppModels: [.small],
            cloudProviders: [],
            transcriptionEngines: [.whisperCpp],
            diarizationEngines: [.sherpaOnnx]
        )
        let essential = PipelineEvaluationMatrix.essentialEntries(from: all)

        #expect(essential.count == 4)
        #expect(essential.allSatisfy { $0.configuration.diarization == .sherpaOnnx })
        #expect(essential.allSatisfy { $0.configuration.transcription == .whisperCpp })
        #expect(Set(essential.map(\.configuration.preprocessing)) == Set(PreprocessingEngine.allCases))
        #expect(Set(essential.map(\.configuration.vad)) == [.energyThreshold, .fluidAudio])
    }

    /// `.transcriptionProviderNative` falls back to `.heuristic` for anything
    /// but a provider that returns its own speaker labels, so pairing it with
    /// an on-device engine would re-measure the heuristic diarizer under a
    /// different label.
    @Test func nativeDiarizationIsPairedOnlyWithProvidersThatDiarize() {
        let entries = PipelineEvaluationMatrix.build(
            whisperCppModels: [.small],
            cloudProviders: [.openAI, .elevenLabs],
            transcriptionEngines: [.whisperCpp],
            diarizationEngines: DiarizationEngine.allCases
        )
        let native = entries.filter { $0.configuration.diarization == .transcriptionProviderNative }

        #expect(!native.isEmpty)
        #expect(native.allSatisfy { $0.configuration.transcription == .whisperAPI })
        #expect(native.allSatisfy { $0.configuration.transcriptionProvider.supportsNativeDiarization })
        #expect(native.allSatisfy { $0.configuration.effectiveDiarization == .transcriptionProviderNative })
        // Every other entry is one diarizer that actually runs under its own name.
        #expect(entries.allSatisfy { $0.configuration.effectiveDiarization == $0.configuration.diarization })
    }

    @Test func cloudProvidersNeedBothSelectionAndKey() {
        let keys = ["OPENAI_API_KEY": "k", "ELEVENLABS_API_KEY": "k", "GROQ_API_KEY": " "]
        #expect(PipelineEvaluationMatrix.cloudProviders(from: nil, environment: keys) == [.openAI, .elevenLabs])
        #expect(PipelineEvaluationMatrix.cloudProviders(from: "none", environment: keys).isEmpty)
        #expect(PipelineEvaluationMatrix.cloudProviders(from: "both", environment: keys) == [.openAI])
        #expect(PipelineEvaluationMatrix.cloudProviders(from: "elevenlabs", environment: keys) == [.elevenLabs])
        #expect(PipelineEvaluationMatrix.cloudProviders(from: "groq, elevenLabs", environment: keys) == [.elevenLabs])
    }

    @Test func cloudModelsExpandOneEntryPerModelAndKeepDefaultLabels() {
        let models = PipelineEvaluationMatrix.cloudModels(from: " openai:gpt-4o-transcribe,openai:whisper-1,bad ")
        #expect(models == ["openai": ["gpt-4o-transcribe", "whisper-1"]])

        let entries = PipelineEvaluationMatrix.build(
            whisperCppModels: [],
            cloudProviders: [.openAI],
            transcriptionEngines: [],
            diarizationEngines: [.fluidAudio],
            cloudModels: models
        )
        let labels = Set(entries.map { $0.label.components(separatedBy: "|asr=").last ?? "" })
        #expect(labels == ["whisperAPI:openAI@gpt-4o-transcribe", "whisperAPI:openAI"])
        #expect(Set(entries.map(\.configuration.transcriptionModel)) == ["gpt-4o-transcribe", "whisper-1"])
    }
}
