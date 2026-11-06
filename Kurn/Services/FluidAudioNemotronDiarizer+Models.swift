import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

extension FluidAudioNemotronDiarizer {
    nonisolated static func processNative(
        url: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> DiarizationOutcome {
        let config = Nemotron3Config.fast32
        let diarizer: Nemotron3Diarizer
        do {
            try Task.checkCancellation()
            var localConfig = config
            localConfig.modelFileName = "\(config.hubSubdirectory)/\(config.modelFileName)"
            let models = try await Nemotron3Models.load(
                config: localConfig,
                directory: FluidAudioDiarizationModelRuntime.nemotronDirectory,
                computeUnits: .cpuAndNeuralEngine
            )
            diarizer = Nemotron3Diarizer(config: config, models: models)
        } catch {
            throw Failure.modelPreparationFailed(error)
        }
        defer { diarizer.reset() }
        let duration = AudioFileDuration.seconds(of: url)
        let started = ContinuousClock.now
        try Task.checkCancellation()
        var timeline = NemotronDiarizationTimeline()
        let samplesPerChunk = config.chunkLen * config.subsamplingFactor * config.sampleRate / 100
        try VADAudioChunkReader.read(
            url: url, sampleRate: Double(config.sampleRate), chunkSize: samplesPerChunk, onProgress: onProgress
        ) { samples in
            try checkBudget(started: started, audioDuration: duration)
            diarizer.appendAudio(samples)
            for chunk in try diarizer.processBufferedAudio() {
                try timeline.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
            }
        }
        try checkBudget(started: started, audioDuration: duration)
        for chunk in try diarizer.finishStream() {
            try timeline.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
        }
        try checkBudget(started: started, audioDuration: duration)
        return DiarizationOutcome(turns: timeline.turns(sourceDuration: duration))
    }

    private nonisolated static func checkBudget(started: ContinuousClock.Instant, audioDuration: TimeInterval) throws {
        try Task.checkCancellation()
        let elapsed = started.duration(to: .now).components
        try NemotronDiarizationPolicy.checkBudget(
            elapsed: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18,
            audioDuration: audioDuration
        )
    }
}
#endif
