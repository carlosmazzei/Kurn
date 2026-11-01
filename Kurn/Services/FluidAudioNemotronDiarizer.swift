import Foundation
import KurnCore

actor FluidAudioNemotronDiarizer: Diarizing {
    struct Operations: Sendable {
        var isInstalled: @Sendable () throws -> Bool
        var process: @Sendable (URL, (@Sendable (Double) -> Void)?) async throws -> DiarizationOutcome
    }

    enum Failure: Error, Sendable {
        case modelPreparationFailed(any Error)
        case engineUnavailable
    }

    private let operations: Operations

    init(operations: Operations = .live) {
        self.operations = operations
    }

    func diarize(url: URL) async -> [SpeakerTurn] {
        await outcome(url: url).turns
    }

    func outcome(
        url: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> DiarizationOutcome {
        do {
            try Task.checkCancellation()
            guard try operations.isInstalled() else {
                AppLog.transcription.atError.error("FluidAudioNemotronDiarizer: selected model is not installed")
                return Self.fallback(url: url, reason: .modelPreparationFailed)
            }
            onProgress?(0)
            let result = try await operations.process(url, onProgress)
            try Task.checkCancellation()
            onProgress?(1)
            guard !result.turns.isEmpty else {
                return Self.fallback(url: url, reason: result.degradation ?? .noInput)
            }
            return DiarizationOutcome(turns: result.turns, degradation: result.degradation)
        } catch let Failure.modelPreparationFailed(error) {
            AppLog.transcription.atError.error("FluidAudioNemotronDiarizer: model preparation failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return Self.fallback(url: url, reason: Task.isCancelled || error is CancellationError ? .engineFailed : .modelPreparationFailed)
        } catch Failure.engineUnavailable {
            onProgress?(1)
            return Self.fallback(url: url, reason: .engineUnavailable)
        } catch {
            AppLog.transcription.atError.error("FluidAudioNemotronDiarizer: processing failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
            return Self.fallback(url: url, reason: .engineFailed)
        }
    }

    private nonisolated static func fallback(url: URL, reason: PipelineStageReason) -> DiarizationOutcome {
        DiarizationOutcome(turns: [AudioFileDuration.wholeClipTurn(for: url)], degradation: reason)
    }
}

extension FluidAudioNemotronDiarizer.Operations {
    static var live: Self {
        Self(
            isInstalled: {
                #if canImport(FluidAudio)
                return FluidAudioDiarizationModelRuntime.isInstalled(.nemotron3)
                #else
                throw FluidAudioNemotronDiarizer.Failure.engineUnavailable
                #endif
            },
            process: { url, onProgress in
                #if canImport(FluidAudio)
                return try await FluidAudioNemotronDiarizer.processNative(url: url, onProgress: onProgress)
                #else
                throw FluidAudioNemotronDiarizer.Failure.engineUnavailable
                #endif
            }
        )
    }
}
