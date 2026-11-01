import Foundation
import KurnCore
import Testing
@testable import Kurn

struct FluidAudioDiarizationRouterTests {
    @Test(arguments: FluidAudioDiarizationModel.allCases)
    func onlyTheSelectedModelReceivesTheOriginalRequest(model: FluidAudioDiarizationModel) async {
        let request = PipelineDiarizationRequest(
            url: URL(fileURLWithPath: "/not-opened.wav"), regions: [], speakerCount: 3,
            onWarning: nil, onProgress: { _ in },
            fluidAudioDiarizationModel: model, fluidAudioSegmentationBatchSize: .balanced
        )
        let router = FluidAudioDiarizationRouter(
            pyannote: { incoming in
                #expect(model == .pyannote)
                #expect(incoming.speakerCount == 3)
                #expect(incoming.fluidAudioSegmentationBatchSize == .balanced)
                #expect(incoming.url == request.url)
                return DiarizationOutcome(turns: [SpeakerTurn(speakerLabel: "old", start: 0, end: 1)])
            },
            nemotron: { incoming in
                #expect(model == .nemotron3)
                #expect(incoming.fluidAudioDiarizationModel == .nemotron3)
                #expect(incoming.url == request.url)
                return DiarizationOutcome(turns: [SpeakerTurn(speakerLabel: "new", start: 0, end: 1)], degradation: .engineFailed)
            }
        )
        let result = await router.diarize(request)
        #expect(result.turns.first?.speakerLabel == (model == .pyannote ? "old" : "new"))
        #expect(result.degradation == (model == .pyannote ? nil : .engineFailed))
        #expect(result.voiceprints.isEmpty)
    }
}
