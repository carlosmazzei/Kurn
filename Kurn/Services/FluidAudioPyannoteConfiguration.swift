import KurnCore

#if canImport(FluidAudio)
import FluidAudio

enum FluidAudioPyannoteConfiguration {
    static func make(_ options: FluidAudioDiarizerConfiguration) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.clustering.numSpeakers = options.pinnedSpeakerCount
        config.segmentation.batchSize = options.segmentationBatchSize.rawValue
        config.exposeChunkEmbeddings = true
        return config
    }
}
#endif
