import KurnCore
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

    @Test func fluidAudioModelFiltersDefaultToTheRecordedModels() {
        #expect(PipelineEvaluationMatrix.fluidAudioASRModels(from: nil) == [.parakeetV3])
        #expect(PipelineEvaluationMatrix.fluidAudioASRModels(from: " ") == [.parakeetV3])
        #expect(PipelineEvaluationMatrix.fluidAudioASRModels(from: "all") == FluidAudioASRModel.allCases)
        #expect(PipelineEvaluationMatrix.fluidAudioASRModels(from: "BARK3, nemotronUnified") == [.nemotronUnified, .bark3])
        #expect(PipelineEvaluationMatrix.fluidAudioDiarizationModels(from: nil) == [.pyannote])
        #expect(PipelineEvaluationMatrix.fluidAudioDiarizationModels(from: "all") == FluidAudioDiarizationModel.allCases)
        #expect(PipelineEvaluationMatrix.fluidAudioDiarizationModels(from: "nemotron3") == [.nemotron3])
    }

    /// Defaults must produce exactly the labels earlier runs recorded, so
    /// `resume` and cross-run tables keep matching.
    @Test func defaultFluidAudioModelsKeepUnsuffixedLabels() {
        let entries = PipelineEvaluationMatrix.build(
            whisperCppModels: [],
            cloudProviders: [],
            transcriptionEngines: [.fluidAudioParakeet],
            diarizationEngines: [.fluidAudio]
        )
        #expect(entries.count == 4)
        #expect(entries.allSatisfy { $0.label.hasSuffix("|diar=fluidAudio|asr=fluidAudioParakeet") })
        #expect(entries.allSatisfy { $0.configuration.fluidAudioASRModel == .parakeetV3 })
        #expect(entries.allSatisfy { $0.configuration.fluidAudioDiarizationModel == .pyannote })
    }

    @Test func fluidAudioModelAxesExpandWithSuffixedLabelsAndModelSets() {
        let entries = PipelineEvaluationMatrix.build(
            whisperCppModels: [],
            cloudProviders: [],
            transcriptionEngines: [.fluidAudioParakeet],
            diarizationEngines: [.heuristic, .fluidAudio],
            fluidAudioASRModels: [.parakeetV3, .bark3],
            fluidAudioDiarizationModels: [.pyannote, .nemotron3]
        )
        // 4 prep x VAD cells x (heuristic once + fluidAudio twice) x 2 ASR models.
        #expect(entries.count == 4 * 3 * 2)
        #expect(Set(entries.map(\.label)).count == entries.count)

        let variant = entries.filter { $0.label.hasSuffix("|diar=fluidAudio@nemotron3|asr=fluidAudioParakeet@bark3") }
        #expect(variant.count == 4)
        #expect(variant.allSatisfy { $0.configuration.fluidAudioASRConsented })
        #expect(variant.allSatisfy {
            FluidAudioPipelineSelection.requiredModelSets(for: $0.configuration)
                .contains(.fluidAudioDiarization(.nemotron3))
        })
        #expect(variant.allSatisfy {
            FluidAudioPipelineSelection.requiredModelSets(for: $0.configuration).contains(.fluidAudioASR(.bark3))
        })
        // The heuristic diarizer has no model axis and keeps its old label.
        let heuristic = entries.filter { $0.configuration.diarization == .heuristic }
        #expect(heuristic.count == 8)
        #expect(heuristic.allSatisfy { $0.label.contains("|diar=heuristic|") })
    }

    @Test func corpusSelectionAcceptsSpacesOrCommasAndBlankMeansAll() {
        #expect(PublicEvaluationDataset.selectedCorpora(from: nil) == nil)
        #expect(PublicEvaluationDataset.selectedCorpora(from: "  ") == nil)
        #expect(PublicEvaluationDataset.selectedCorpora(from: "ami-en voxconverse-en") == ["ami-en", "voxconverse-en"])
        #expect(PublicEvaluationDataset.selectedCorpora(from: "ami-en,coraa-pt") == ["ami-en", "coraa-pt"])
    }
}
