public enum FluidAudioSegmentationBatchSize: Int, Codable, Sendable, CaseIterable, Identifiable {
    case lowMemory = 4
    case balanced = 8
    case throughput = 16
    case maximum = 32

    public static let `default`: Self = .maximum
    public static let recommended: Self = .balanced

    public var id: Int { rawValue }
}
