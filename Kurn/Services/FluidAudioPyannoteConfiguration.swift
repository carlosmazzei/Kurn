import KurnCore

#if canImport(FluidAudio)
import FluidAudio

enum FluidAudioPyannoteConfiguration {
    static func make(_ options: FluidAudioDiarizerConfiguration) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.clustering.numSpeakers = options.pinnedSpeakerCount
        config.segmentation.batchSize = options.segmentationBatchSize.rawValue
        config.exposeChunkEmbeddings = true
        // One speaker per instant, as the app's pipeline has always received: TranscriptFusion
        // attributes each span to a single speaker. FluidAudio 0.18.2 changed this default to false
        // (overlapping turns, pyannote's scored output), so it is pinned rather than inherited.
        config.postProcessing.exclusiveSegments = true
        return config
    }
}
#endif
