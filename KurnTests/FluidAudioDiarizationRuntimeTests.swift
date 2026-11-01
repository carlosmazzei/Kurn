import KurnCore
import Testing
@testable import Kurn

#if canImport(FluidAudio)
import FluidAudio

struct FluidAudioDiarizationRuntimeTests {
    @Test func selectedBatchPreservesAllOtherOfflineDefaults() {
        let defaults = OfflineDiarizerConfig.default
        for batch in FluidAudioSegmentationBatchSize.allCases {
            let config = FluidAudioPyannoteConfiguration.make(FluidAudioDiarizerConfiguration(
                speakerCount: 3, segmentationBatchSize: batch
            ))
            #expect(config.segmentation.batchSize == batch.rawValue)
            #expect(config.clustering.numSpeakers == 3)
            #expect(config.exposeChunkEmbeddings)
            #expect(config.segmentation.windowDurationSeconds == defaults.segmentation.windowDurationSeconds)
            #expect(config.segmentation.stepRatio == defaults.segmentation.stepRatio)
            #expect(config.embedding.batchSize == defaults.embedding.batchSize)
            #expect(config.clustering.warmStartFa == defaults.clustering.warmStartFa)
            #expect(config.clustering.warmStartFb == defaults.clustering.warmStartFb)
        }
        let automatic = FluidAudioPyannoteConfiguration.make(FluidAudioDiarizerConfiguration())
        #expect(automatic.clustering.numSpeakers == nil)
        #expect(automatic.segmentation.batchSize == 32)
        #expect(automatic.exposeChunkEmbeddings)
    }
}
#endif
