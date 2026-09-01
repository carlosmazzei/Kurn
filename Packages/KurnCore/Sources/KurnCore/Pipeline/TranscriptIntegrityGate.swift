//
//  TranscriptIntegrityGate.swift
//  KurnCore
//
//  The final check before one transcription run's output is trusted enough to
//  replace whatever transcript already exists (H5 PR 12,
//  `docs/resilience-megaplan.md`). Every stage before this one — the ASR
//  engine, `TranscriptFusion`, an LLM `TranscriptCorrecting` conformer — is
//  pure and cannot throw, so nothing upstream stops a structurally broken
//  result from reaching the save path on its own. This is that stop:
//  `TranscriptionService.transcribe` throws instead of returning `Output` when
//  it fails, so `TranscriptionViewModel.saveTranscript` — the only place an
//  existing transcript is deleted — is never reached with bad data. Whatever
//  transcript existed before this run stays exactly as it was.
//
//  Closed vocabulary, the same reason `PipelineStageReason` has one: the
//  failure is logged and is a diagnostics-export candidate, so a raw
//  timestamp, speaker name, or transcript text must never reach it.
//

import Foundation

/// Why the final gate rejected a run's output. Never carries a timestamp,
/// text, or speaker name — only which invariant broke.
public enum TranscriptIntegrityFailure: String, Codable, Sendable, CaseIterable {
    /// The source recording's duration could not be established, so nothing
    /// about a segment's bounds can be trusted either.
    case sourceUnreadable
    /// The engine produced spans, but the fused output is empty. Fusion is
    /// pure and cannot fail — this is the shape a bug in it (or in the input
    /// it was given) takes instead of a thrown error.
    case emptyOutputFromNonEmptyInput
    /// A segment's timestamps are non-finite, negative, inverted
    /// (`end < start`), or fall well outside the source recording's duration.
    case segmentOutOfBounds
    /// Segments are not in roughly chronological order.
    case segmentsOutOfOrder
    /// A segment carries no text, or only whitespace.
    case emptySegmentText
    /// A segment carries no speaker attribution at all.
    case unattributedSpeaker
    /// A `TranscriptCorrecting` conformer returned a different segment count,
    /// different ids, a different order, or changed a field other than
    /// `.text` — violating the contract every caller relies on.
    case correctionIdentityViolation
}

/// Validates a finished run's fused, corrected segments before they are
/// allowed to replace an existing transcript. Pure and Linux-buildable like
/// the rest of `Pipeline/`, so it is testable without the Apple toolchain.
public enum TranscriptIntegrityGate {
    /// Same tolerance `TranscriptionCheckpoint.isStructurallyValid` uses, for
    /// the same reason: a gross-corruption catcher, not an exact
    /// re-derivation of chunk-boundary rounding or the compacted timeline.
    public static let boundsSlack: TimeInterval = 30

    /// - Parameters:
    ///   - hadTranscribedInput: whether the ASR engine produced any spans
    ///     before fusion. An empty `segments` is only a failure when it lost
    ///     content that existed — a recording with genuinely no speech is not
    ///     an integrity failure.
    public static func validate(
        segments: [TranscriptSegment],
        sourceDuration: TimeInterval,
        hadTranscribedInput: Bool
    ) -> TranscriptIntegrityFailure? {
        guard sourceDuration.isFinite, sourceDuration >= 0 else {
            return .sourceUnreadable
        }
        guard !segments.isEmpty else {
            return hadTranscribedInput ? .emptyOutputFromNonEmptyInput : nil
        }

        let upperBound = sourceDuration + boundsSlack
        var maxStartSoFar: TimeInterval = -boundsSlack
        for segment in segments {
            guard segment.startTime.isFinite, segment.endTime.isFinite,
                  segment.startTime >= 0, segment.endTime >= segment.startTime,
                  segment.startTime <= upperBound, segment.endTime <= upperBound else {
                return .segmentOutOfBounds
            }
            guard segment.startTime >= maxStartSoFar - boundsSlack else {
                return .segmentsOutOfOrder
            }
            maxStartSoFar = max(maxStartSoFar, segment.startTime)
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .emptySegmentText
            }
            guard !segment.speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .unattributedSpeaker
            }
        }
        return nil
    }

    /// Whether a `TranscriptCorrecting` conformer honored its documented
    /// contract (`PipelineStages.swift`): the same count, in the same order,
    /// same ids, with every field except `.text` unchanged. A conformer that
    /// violates this is treated as having failed, not as having corrected —
    /// see `TranscriptionServiceCorrection.correctIfRequested`.
    public static func correctionPreservedIdentity(
        original: [TranscriptSegment],
        corrected: [TranscriptSegment]
    ) -> Bool {
        guard original.count == corrected.count else { return false }
        for (before, after) in zip(original, corrected) {
            guard before.id == after.id,
                  before.speakerLabel == after.speakerLabel,
                  before.startTime == after.startTime,
                  before.endTime == after.endTime,
                  before.confidence == after.confidence else {
                return false
            }
        }
        return true
    }
}
