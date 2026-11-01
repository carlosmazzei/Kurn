import Foundation

public enum NemotronDiarizationPolicy {
    public enum Failure: Error, Sendable, Equatable {
        case timeBudgetExceeded
    }

    public static let speakerSlots = 8
    public static let frameSeconds: TimeInterval = 0.01
    public static let activityThreshold: Float = 0.5
    public static let minimumSpeechDuration: TimeInterval = 0.2

    public static func processTimeout(forAudioDuration duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite else { return duration == .infinity ? 1800 : 180 }
        return min(1800, max(180, duration * 0.5))
    }

    public static func checkBudget(elapsed: TimeInterval, audioDuration: TimeInterval) throws {
        guard elapsed.isFinite, elapsed <= processTimeout(forAudioDuration: audioDuration) else {
            throw Failure.timeBudgetExceeded
        }
    }

    public static func isInstalled(
        cachedVersion: String?,
        expectedVersion: String,
        hasCompiledManifest: Bool,
        silenceEmbeddingByteCount: Int?
    ) -> Bool {
        cachedVersion?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedVersion
            && hasCompiledManifest
            && silenceEmbeddingByteCount == 512 * MemoryLayout<Float>.size
    }
}
