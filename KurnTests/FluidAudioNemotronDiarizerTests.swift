import Foundation
import KurnCore
import Synchronization
import Testing
@testable import Kurn

struct FluidAudioNemotronDiarizerTests {
    private static let url = URL(fileURLWithPath: "/missing-nemotron-policy-test.m4a")
    private static let turns = [SpeakerTurn(speakerLabel: "Speaker 1", start: 0.25, end: 1.5)]

    @Test func missingModelNeverProcessesOrDownloadsAndReturnsAnExplicitFallback() async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { false },
            process: { _, _ in
                Issue.record("Missing models must not enter native processing")
                throw CancellationError()
            }
        ))
        let result = await diarizer.outcome(url: Self.url)
        Self.expectFallback(result, reason: .modelPreparationFailed)
    }

    @Test func preparedSuccessPreservesTurnsAndForwardsProgressWithoutVoiceprints() async {
        let progress = Mutex<[Double]>([])
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true },
            process: { url, onProgress in
                #expect(url == Self.url)
                onProgress?(0.4)
                return DiarizationOutcome(turns: Self.turns)
            }
        ))
        let result = await diarizer.outcome(url: Self.url) { fraction in
            progress.withLock { $0.append(fraction) }
        }
        #expect(result.turns == Self.turns)
        #expect(result.degradation == nil)
        #expect(result.voiceprints.isEmpty)
        #expect(progress.withLock { $0 } == [0, 0.4, 1])
    }

    @Test(arguments: [PipelineStageReason.modelPreparationFailed, .engineFailed, .noInput])
    func preparedDegradationIsRetained(reason: PipelineStageReason) async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true },
            process: { _, onProgress in
                #expect(onProgress == nil)
                return DiarizationOutcome(turns: Self.turns, degradation: reason)
            }
        ))
        let result = await diarizer.outcome(url: Self.url)
        #expect(result.turns == Self.turns)
        #expect(result.degradation == reason)
        #expect(result.voiceprints.isEmpty)
    }

    @Test func emptySuccessBecomesNoInputFallback() async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true }, process: { _, _ in DiarizationOutcome(turns: []) }
        ))
        Self.expectFallback(await diarizer.outcome(url: Self.url), reason: .noInput)
    }

    @Test func emptyDegradedResultRetainsItsFailureReason() async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true },
            process: { _, _ in DiarizationOutcome(turns: [], degradation: .engineFailed) }
        ))
        Self.expectFallback(await diarizer.outcome(url: Self.url), reason: .engineFailed)
    }

    @Test func nativePreparationFailureIsNotMisreportedAsProcessingFailure() async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true },
            process: { _, _ in throw FluidAudioNemotronDiarizer.Failure.modelPreparationFailed(ScriptedFailure()) }
        ))
        Self.expectFallback(await diarizer.outcome(url: Self.url), reason: .modelPreparationFailed)
    }

    @Test func unexpectedProcessingFailureSafelyFallsBack() async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true }, process: { _, _ in throw ScriptedFailure() }
        ))
        Self.expectFallback(await diarizer.outcome(url: Self.url), reason: .engineFailed)
    }

    @Test func unavailableEngineNeverProcessesAndCompletesProgress() async {
        let progress = Mutex<[Double]>([])
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { throw FluidAudioNemotronDiarizer.Failure.engineUnavailable },
            process: { _, _ in
                Issue.record("An unavailable engine must not process")
                throw CancellationError()
            }
        ))
        let result = await diarizer.outcome(url: Self.url) { fraction in
            progress.withLock { $0.append(fraction) }
        }
        Self.expectFallback(result, reason: .engineUnavailable)
        #expect(progress.withLock { $0 } == [1])
    }

    @Test func cancellationBeforeStartingNeverProbesOrProcesses() async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: {
                Issue.record("A cancelled run must not probe models")
                return true
            },
            process: { _, _ in
                Issue.record("A cancelled run must not process")
                throw CancellationError()
            }
        ))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await diarizer.outcome(url: Self.url)
        }
        Self.expectFallback(await task.value, reason: .engineFailed)
    }

    @Test func cancellationDuringProcessingNeverEscapesTheActor() async {
        let (started, signal) = AsyncStream<Void>.makeStream()
        defer { signal.finish() }
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true },
            process: { _, _ in
                signal.yield(())
                try await Task.sleep(for: .seconds(60))
                return DiarizationOutcome(turns: Self.turns)
            }
        ))
        let task = Task { await diarizer.outcome(url: Self.url) }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        Self.expectFallback(await task.value, reason: .engineFailed)
    }

    @Test(arguments: [false, true])
    func cancellationDuringPreparationIsNotADownloadFailure(nativeCancellation: Bool) async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true },
            process: { _, _ in
                if nativeCancellation {
                    throw FluidAudioNemotronDiarizer.Failure.modelPreparationFailed(CancellationError())
                }
                withUnsafeCurrentTask { $0?.cancel() }
                throw FluidAudioNemotronDiarizer.Failure.modelPreparationFailed(ScriptedFailure())
            }
        ))
        let task = Task { await diarizer.outcome(url: Self.url) }
        Self.expectFallback(await task.value, reason: .engineFailed)
    }

    @Test func cancellationAfterAnOperationReturnsDiscardsTheSuccess() async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true },
            process: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return DiarizationOutcome(turns: Self.turns)
            }
        ))
        let task = Task { await diarizer.outcome(url: Self.url) }
        Self.expectFallback(await task.value, reason: .engineFailed)
    }

    @Test func diarizeKeepsItsExistingTurnsOnlyContract() async {
        let diarizer = FluidAudioNemotronDiarizer(operations: .init(
            isInstalled: { true }, process: { _, _ in DiarizationOutcome(turns: Self.turns) }
        ))
        #expect(await diarizer.diarize(url: Self.url) == Self.turns)
    }

    @Test func constructingDefaultOperationsDoesNotLoadModels() {
        _ = FluidAudioNemotronDiarizer()
    }

    private static func expectFallback(_ result: DiarizationOutcome, reason: PipelineStageReason) {
        #expect(result.turns == [AudioFileDuration.wholeClipTurn(for: url)])
        #expect(result.voiceprints.isEmpty)
        #expect(result.degradation == reason)
    }

    private struct ScriptedFailure: Error {}
}
