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
}
