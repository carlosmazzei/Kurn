//
//  DiarizationFinalization.swift
//  Kurn
//
//  Everything the neural diarizer decides after the model has spoken: whether
//  to rescue a collapsed clustering, smoothing, voiceprints, and how long the
//  run may take. Kept out of `FluidAudioDiarizer`, which needs FluidAudio's
//  downloaded models to run at all, so these decisions are testable without
//  them.
//

import Foundation
import KurnCore

/// What the neural diarizer produces beyond the turns themselves.
///
/// The voiceprints are the reason this type exists. The model computes a speaker
/// embedding per window and the diarizer used to drop every one of them on the
/// way out, which left `"Speaker 2"` — a label reassigned in order of first
/// appearance on every run — as the only identity a `Speaker` row could be keyed
/// on. Carrying the centroid out is what lets a name the user typed follow the
/// voice instead of the number.
///
/// Empty for the heuristic engine, which has no embeddings to give.
struct DiarizationOutcome: Sendable {
    var turns: [SpeakerTurn]
    /// Speaker label → L2-normalized mean embedding.
    var voiceprints: [String: [Float]]
    /// Why these turns are not what the requested engine was supposed to
    /// produce, or `nil` when they are. Carried out of the engine because a
    /// single whole-clip turn is indistinguishable from a genuine
    /// one-speaker meeting once it reaches fusion (H5 PR 11).
    var degradation: PipelineStageReason?

    init(
        turns: [SpeakerTurn],
        voiceprints: [String: [Float]] = [:],
        degradation: PipelineStageReason? = nil
    ) {
        self.turns = turns
        self.voiceprints = voiceprints
        self.degradation = degradation
    }
}

enum DiarizationFinalization {

    /// The engine's labeled turns, repaired and described.
    ///
    /// - A clustering that reported a single speaker is re-clustered from the
    ///   per-window embeddings (`SpeakerClusterRefiner`), keeping the
    ///   diarizer's own boundaries; a genuinely single voice is left alone.
    /// - Every result is smoothed (`SpeakerTurnSmoothing`).
    /// - Voiceprints are computed last, so they describe the speakers as
    ///   finally reported rather than as first clustered.
    static func outcome(
        turns: [SpeakerTurn],
        distinctSpeakers: Int,
        windows: [SpeakerEmbeddingWindow]?
    ) -> DiarizationOutcome {
        var turns = turns
        if distinctSpeakers <= 1, let windows {
            turns = rescueCollapsedSpeakers(turns: turns, windows: windows)
        }
        let smoothed = SpeakerTurnSmoothing.smooth(turns)
        AppLog.transcription.atInfo.info("FluidAudioDiarizer: smoothed turns \(turns.count, privacy: .public) -> \(smoothed.count, privacy: .public), speakers=\(Set(smoothed.map { $0.speakerLabel }).count, privacy: .public)")

        let voiceprints = windows.map {
            SpeakerVoiceprints.centroids(turns: smoothed, windows: $0)
        } ?? [:]
        if !voiceprints.isEmpty {
            AppLog.transcription.atInfo.info("FluidAudioDiarizer: voiceprints for \(voiceprints.count, privacy: .public) speaker(s)")
        }
        return DiarizationOutcome(turns: smoothed, voiceprints: voiceprints)
    }

    /// Re-cluster the per-window speaker embeddings that VBx collapsed and
    /// re-attribute the diarizer's own segment boundaries to the result. Keeps
    /// `turns` unchanged when the embeddings genuinely hold a single voice.
    static func rescueCollapsedSpeakers(
        turns: [SpeakerTurn],
        windows: [SpeakerEmbeddingWindow]
    ) -> [SpeakerTurn] {
        guard let labels = SpeakerClusterRefiner.clusterLabels(for: windows) else {
            AppLog.transcription.atInfo.info("FluidAudioDiarizer: single cluster confirmed by re-clustering \(windows.count, privacy: .public) windows")
            return turns
        }
        let rescued = SpeakerClusterRefiner.reassign(turns: turns, windows: windows, labels: labels)
        let speakers = Set(rescued.map { $0.speakerLabel }).count
        AppLog.transcription.atNotice.notice("FluidAudioDiarizer: recovered \(speakers, privacy: .public) speakers from \(windows.count, privacy: .public) embedding windows after VBx collapse")
        return rescued
    }

    /// An engine result that produced no turns is reported as a single
    /// whole-clip turn, marked as degraded so it is not mistaken for a genuine
    /// one-speaker meeting.
    static func nonEmpty(_ outcome: DiarizationOutcome, fallback: SpeakerTurn) -> DiarizationOutcome {
        outcome.turns.isEmpty ? DiarizationOutcome(turns: [fallback], degradation: .noInput) : outcome
    }
}

extension FluidAudioDiarizer {
    /// Processing budget scaled to the recording.
    ///
    /// This used to be a flat 120s, which a one-hour meeting can exceed on an
    /// older device even when everything is working — and the timeout path
    /// falls back to a single whole-clip turn, so the symptom was every long
    /// recording silently coming back as one speaker. Diarization runs well
    /// under real time on the ANE, so half of the recording's duration is a
    /// generous budget; the floor keeps short clips from tripping on model
    /// warm-up and the ceiling still bounds a genuinely stuck run.
    static func processTimeout(forAudioDuration duration: TimeInterval) -> TimeInterval {
        min(1800, max(180, duration * 0.5))
    }
}
