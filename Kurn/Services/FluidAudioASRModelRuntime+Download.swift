import Foundation
import KurnCore

#if canImport(FluidAudio)
import CoreML
import FluidAudio

extension FluidAudioASRModelRuntime {
    static func download(
        _ model: FluidAudioASRModel,
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) async throws {
        onProgress(ModelDownloadStatus(fractionCompleted: 0, phase: .preparing))
        let handler = progressHandler(onProgress)
        switch FluidAudioRuntimePolicy.backend(for: model) {
        case .parakeetV3, .tdt:
            if let version = asrVersion(for: model) {
                _ = try await AsrModels.downloadAndLoad(version: version, progressHandler: handler)
            }
        case .unified:
            let manager = UnifiedAsrManager(config: unifiedConfig(.auto), encoderPrecision: unifiedPrecision)
            do {
                try await manager.loadModels(to: nil, configuration: nil, progressHandler: handler)
            } catch {
                await manager.cleanup()
                throw error
            }
            await manager.cleanup()
        case .transcribeLite:
            _ = try await NemotronTranscribeLiteModels.downloadAndLoad(
                computeUnits: transcribeLiteComputeUnits, progressHandler: handler
            )
        }
        onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
        try await ResourceGuard.requireModelDownloadHeadroom()
    }

    static func downloadUnifiedStreaming(
        onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) async throws {
        onProgress(ModelDownloadStatus(fractionCompleted: 0, phase: .preparing))
        let manager = StreamingUnifiedAsrManager(config: unifiedConfig(.auto), encoderPrecision: unifiedPrecision)
        do {
            try await manager.loadModels(to: nil, configuration: nil, progressHandler: progressHandler(onProgress))
        } catch {
            await manager.cleanup()
            throw error
        }
        await manager.cleanup()
        onProgress(ModelDownloadStatus(fractionCompleted: 1, phase: .compiling))
        try await ResourceGuard.requireModelDownloadHeadroom()
    }

    static func progressHandler(
        _ onProgress: @escaping @Sendable (ModelDownloadStatus) -> Void
    ) -> ProgressHandler {
        { onProgress(downloadStatus(for: $0)) }
    }
}
#endif
