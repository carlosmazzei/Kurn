public struct FluidAudioDiarizerConfiguration: Sendable, Hashable {
    public let speakerCount: Int
    public let segmentationBatchSize: FluidAudioSegmentationBatchSize

    public init(
        speakerCount: Int = 0,
        segmentationBatchSize: FluidAudioSegmentationBatchSize = .maximum
    ) {
        self.speakerCount = speakerCount > 1 ? speakerCount : 0
        self.segmentationBatchSize = segmentationBatchSize
    }

    public var pinnedSpeakerCount: Int? { speakerCount > 1 ? speakerCount : nil }
}
