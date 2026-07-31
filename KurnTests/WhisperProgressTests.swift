//
//  WhisperProgressTests.swift
//  KurnTests
//
//  Keeps the synthetic Whisper progress estimator honest. The API does not
//  expose upload/server-side progress, so the UI uses a bounded estimate while
//  each chunk is in flight and the real completion event marks the chunk done.
//

import Foundation
import Testing
@testable import Kurn

struct WhisperProgressTests {

    @Test func estimatedProgressStartsAtCompletedChunkBoundary() {
        #expect(WhisperTranscriber.estimatedProgress(completedChunks: 0, totalChunks: 1, elapsed: 0) == 0)
        #expect(WhisperTranscriber.estimatedProgress(completedChunks: 1, totalChunks: 4, elapsed: 0) == 0.25)
    }

    @Test func estimatedProgressAdvancesWithoutReachingComplete() {
        let early = WhisperTranscriber.estimatedProgress(completedChunks: 0, totalChunks: 1, elapsed: 2)
        let later = WhisperTranscriber.estimatedProgress(completedChunks: 0, totalChunks: 1, elapsed: 30)
        let muchLater = WhisperTranscriber.estimatedProgress(completedChunks: 0, totalChunks: 1, elapsed: 300)

        #expect(early > 0)
        #expect(later > early)
        #expect(muchLater > later)
        #expect(muchLater < 1)
    }

    @Test func estimatedProgressStaysWithinCurrentChunkBand() {
        let progress = WhisperTranscriber.estimatedProgress(completedChunks: 2, totalChunks: 4, elapsed: 300)

        #expect(progress > 0.5)
        #expect(progress < 0.75)
    }

    @Test func estimatedProgressReturnsCompleteOnlyWhenAllChunksAreDone() {
        #expect(WhisperTranscriber.estimatedProgress(completedChunks: 4, totalChunks: 4, elapsed: 0) == 1)
        #expect(WhisperTranscriber.estimatedProgress(completedChunks: 6, totalChunks: 4, elapsed: 0) == 1)
    }

    @Test func postTranscriptionWorkHasDistinctUserFacingPhases() {
        let phases: [PostTranscriptionPhase] = [
            .generatingTitle,
            .indexing,
            .generatingWiki
        ]
        let names = phases.map(\.displayName)

        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == phases.count)
    }

    @Test func diarizationHasAnHonestPhaseAfterCompletedTranscription() {
        let completedTranscription = TranscriptionPhase.transcribing(progress: 1, chunks: nil)
        let earlyDiarization = TranscriptionPhase.diarizing(progress: 0.2)
        let lateDiarization = TranscriptionPhase.diarizing(progress: 0.8)

        #expect(earlyDiarization.displayName != completedTranscription.displayName)
        #expect(earlyDiarization.displayName != lateDiarization.displayName)
        #expect(earlyDiarization.fractionComplete > completedTranscription.fractionComplete)
        #expect(lateDiarization.fractionComplete > earlyDiarization.fractionComplete)
        #expect(lateDiarization.fractionComplete < TranscriptionPhase.finalizing.fractionComplete)
    }

    @Test func concurrentDiarizationProgressWaitsForTranscriptionAndNeverRegresses() {
        let snapshots = PhaseSnapshots()
        let relay = DiarizationPhaseRelay { snapshots.append($0) }

        relay.update(0.2)
        relay.update(0.6)
        #expect(snapshots.values.isEmpty)

        relay.reveal()
        relay.update(0.4)
        relay.update(0.8)

        #expect(snapshots.diarizationProgress == [0.6, 0.8])
    }
}

private final class PhaseSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [TranscriptionPhase] = []

    func append(_ phase: TranscriptionPhase) {
        lock.withLock { phases.append(phase) }
    }

    var values: [TranscriptionPhase] {
        lock.withLock { phases }
    }

    var diarizationProgress: [Double] {
        values.compactMap { phase in
            guard case .diarizing(let progress) = phase else { return nil }
            return progress
        }
    }
}
