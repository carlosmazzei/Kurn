import Foundation

#if canImport(FluidAudio)
import FluidAudio

extension FluidAudioAutomaticStreamingRuntime {
    static func loadLocal(_ backend: Backend) async throws -> any StreamingAsrManager {
        switch backend {
        case .english:
            let manager = StreamingEouAsrManager(chunkSize: .ms160)
            do {
                try await manager.loadModels(from: englishDirectory)
            } catch {
                await manager.cleanup()
                throw error
            }
            return manager
        case .multilingual:
            let manager = FluidAudioMultilingualStreamingManager()
            do {
                try await manager.loadModels()
            } catch {
                await manager.cleanup()
                throw error
            }
            return manager
        }
    }
}
#endif
