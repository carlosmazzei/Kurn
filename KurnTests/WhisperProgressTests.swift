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
        let diarization = TranscriptionPhase.diarizing

        #expect(diarization.displayName != completedTranscription.displayName)
        #expect(diarization.fractionComplete > completedTranscription.fractionComplete)
        #expect(diarization.fractionComplete < TranscriptionPhase.finalizing.fractionComplete)
    }
}
