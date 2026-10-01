//
//  DiarizationPhaseRelay.swift
//  Kurn
//

import Foundation

/// Thread-safe bridge between diarization's concurrent callbacks and the phase
/// shown by the UI. Cloud transcription and diarization start together, but the
/// UI must keep showing transcription until its result is complete. Progress is
/// accumulated meanwhile and revealed atomically once Whisper finishes.
final class DiarizationPhaseRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latestProgress = 0.0
    private var isRevealed = false
    private let onPhase: TranscriptionService.PhaseHandler

    init(onPhase: @escaping TranscriptionService.PhaseHandler) {
        self.onPhase = onPhase
    }

    func update(_ progress: Double) {
        let phase: TranscriptionPhase? = lock.withLock {
            let clampedProgress = min(1, max(0, progress))
            guard clampedProgress > latestProgress else { return nil }
            latestProgress = clampedProgress
            return isRevealed ? .diarizing(progress: latestProgress) : nil
        }
        if let phase { onPhase(phase) }
    }

    func reveal() {
        let progress = lock.withLock {
            isRevealed = true
            return latestProgress
        }
        onPhase(.diarizing(progress: progress))
    }
}
