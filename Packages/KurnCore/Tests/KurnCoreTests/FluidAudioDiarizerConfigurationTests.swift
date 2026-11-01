import Testing
@testable import KurnCore

struct FluidAudioDiarizerConfigurationTests {
    @Test func preservesTheOriginalAutomaticAndMaximumBatchDefaults() {
        let config = FluidAudioDiarizerConfiguration()
        #expect(config.speakerCount == 0)
        #expect(config.pinnedSpeakerCount == nil)
        #expect(config.segmentationBatchSize == .maximum)
        #expect(config.segmentationBatchSize.rawValue == 32)
    }

    @Test func speakerCountsOfZeroOneAndNegativeRemainUnconstrained() {
        for count in [-5, 0, 1] {
            let config = FluidAudioDiarizerConfiguration(speakerCount: count)
            #expect(config == FluidAudioDiarizerConfiguration())
            #expect(config.pinnedSpeakerCount == nil)
        }
    }

    @Test func pinsMultipleSpeakersWithoutChangingTheSelectedBatch() {
        for batch in FluidAudioSegmentationBatchSize.allCases {
            let config = FluidAudioDiarizerConfiguration(speakerCount: 3, segmentationBatchSize: batch)
            #expect(config.speakerCount == 3)
            #expect(config.pinnedSpeakerCount == 3)
            #expect(config.segmentationBatchSize == batch)
        }
    }

    @Test func managerCacheKeyChangesForEitherSpeakerCountOrBatch() {
        let original = FluidAudioDiarizerConfiguration(speakerCount: 2, segmentationBatchSize: .maximum)
        #expect(original == FluidAudioDiarizerConfiguration(speakerCount: 2))
        #expect(original != FluidAudioDiarizerConfiguration(speakerCount: 3))
        for batch in [FluidAudioSegmentationBatchSize.lowMemory, .balanced, .throughput] {
            #expect(original != FluidAudioDiarizerConfiguration(speakerCount: 2, segmentationBatchSize: batch))
        }
        #expect(Set([
            original, original,
            FluidAudioDiarizerConfiguration(speakerCount: 3),
            FluidAudioDiarizerConfiguration(speakerCount: 2, segmentationBatchSize: .balanced)
        ]).count == 3)
    }
}
