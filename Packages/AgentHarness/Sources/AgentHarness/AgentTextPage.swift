import Foundation

/// A lossless Unicode-scalar continuation bounded by both tokens' proxy and wire bytes.
public struct AgentTextPage: Sendable {
    public struct NoProgress: Error {}
    public let text: String
    public let totalScalars: Int
    public let nextOffset: Int
    public let returnedScalars: Int
    public var hasMore: Bool { nextOffset < totalScalars }
    public var metrics: [AgentDiagnostic.Metric: Int] {
        [.availableScalars: totalScalars, .returnedScalars: returnedScalars,
         .deferredScalars: totalScalars - nextOffset, .hasMore: hasMore ? 1 : 0]
    }

    public init(_ text: String, offset: Int, maxScalars: Int = 8_000, maxBytes: Int = 17_800) throws {
        let scalars = text.unicodeScalars
        totalScalars = scalars.count
        let start = min(totalScalars, max(0, offset))
        var chunk = String.UnicodeScalarView()
        var bytes = 0
        for scalar in scalars.dropFirst(start).prefix(max(0, maxScalars)) {
            let size = scalar.utf8.count
            guard bytes + size <= max(0, maxBytes) else { break }
            chunk.append(scalar)
            bytes += size
        }
        self.text = String(chunk)
        returnedScalars = chunk.count
        nextOffset = start + returnedScalars
        if nextOffset < totalScalars && returnedScalars == 0 { throw NoProgress() }
    }
}
