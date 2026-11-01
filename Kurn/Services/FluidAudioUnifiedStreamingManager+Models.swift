import Foundation

#if canImport(FluidAudio)
import FluidAudio

extension FluidAudioUnifiedStreamingManager {
    static func loadLocal(unifiedLanguage: NemotronUnifiedLanguage) async throws -> any StreamingAsrManager {
        let candidate = StreamingUnifiedAsrManager(
            config: FluidAudioASRModelRuntime.unifiedConfig(unifiedLanguage),
            encoderPrecision: FluidAudioASRModelRuntime.unifiedPrecision
        )
        do {
            try await candidate.loadModels(from: FluidAudioASRModelRuntime.unifiedDirectory)
        } catch {
            await candidate.cleanup()
            throw error
        }
        return candidate
    }
}

extension StreamingUnifiedAsrManager: FluidAudioStreamingTimingDiscarding {
    func discardTokenTimings() {
        _ = consumeTokenTimings()
    }
}
#endif
