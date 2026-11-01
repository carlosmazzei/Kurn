import Foundation
import KurnCore

#if canImport(FluidAudio)
import AVFoundation
import CoreML
import FluidAudio

extension FluidAudioModelTranscriber {
    static func transcribeTDT(
        url: URL,
        version: AsrModelVersion,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> RawTranscript {
        let duration = (try? await AVURLAsset(url: url).load(.duration)).map(CMTimeGetSeconds) ?? 0
        let manager = try await withResourceReservation(.modelLoading) {
            let models = try AsrModels.loadLocal(from: AsrModels.defaultCacheDirectory(for: version), version: version)
            return AsrManager(config: .default, models: models)
        }
        var progressTask: Task<Void, Never>?
        if BatchTranscriptAssembly.reportsProgress(forDuration: duration) {
            let stream = await manager.transcriptionProgressStream
            progressTask = Task {
                do {
                    for try await fraction in stream {
                        onProgress(BatchTranscriptAssembly.clampedFraction(fraction))
                    }
                } catch {
                    return
                }
            }
        }
        defer { progressTask?.cancel() }
        let result: ASRResult
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            result = try await manager.transcribe(url, decoderState: &decoderState)
        } catch {
            await manager.cleanup()
            throw error
        }
        await manager.cleanup()
        return transcript(from: result)
    }

    static func transcribeUnified(url: URL, unifiedLanguage: NemotronUnifiedLanguage) async throws -> RawTranscript {
        let samples = try AudioConverter().resampleAudioFile(url)
        let manager = UnifiedAsrManager(
            config: FluidAudioASRModelRuntime.unifiedConfig(unifiedLanguage),
            encoderPrecision: FluidAudioASRModelRuntime.unifiedPrecision
        )
        let result: ASRResult
        do {
            try await withResourceReservation(.modelLoading) {
                try await manager.loadModels(from: FluidAudioASRModelRuntime.unifiedDirectory)
            }
            result = try await manager.transcribeDetailed(samples)
        } catch {
            await manager.cleanup()
            throw error
        }
        await manager.cleanup()
        return transcript(from: result)
    }

    static func transcribeLite(url: URL) async throws -> RawTranscript {
        let samples = try AudioConverter().resampleAudioFile(url)
        let models = try await withResourceReservation(.modelLoading) {
            try NemotronTranscribeLiteModels.load(
                from: FluidAudioASRModelRuntime.transcribeLiteDirectory,
                computeUnits: FluidAudioASRModelRuntime.transcribeLiteComputeUnits
            )
        }
        let result = try await NemotronTranscribeLiteManager(models: models).transcribe(audio: samples)
        return try transcript(
            from: result.words.map { FluidAudioStartTimedWord(text: $0.text, start: $0.start) },
            duration: result.durationSeconds
        )
    }
}
#endif
