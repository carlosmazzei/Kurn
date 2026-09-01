//
//  PipelineReport.swift
//  KurnCore
//
//  What actually happened in each stage of one transcription run, as values
//  rather than log lines. Fallback is legitimate here — preprocessing can use
//  the original file, and a transcript is better than no transcript because
//  diarization failed — but until this type existed the *fact* of the fallback
//  only survived in the log: the finished transcript claimed the requested
//  engine had succeeded (`docs/resilience-megaplan.md`, H5 PR 11).
//
//  Every field is a closed vocabulary or an engine `rawValue`. There is
//  deliberately no free-text/`underlyingError` field: this report is persisted
//  beside the transcript and is a candidate for diagnostics export, so a
//  provider message, file name, or URL must not be able to reach it. A stage
//  that needs more detail than `PipelineStageReason` offers adds a reason case
//  here instead.
//

import Foundation

/// One stage of the recognition pipeline, in execution order.
public enum PipelineStage: String, Codable, Sendable, CaseIterable {
    case preprocessing
    case languageDetection
    case voiceActivityDetection
    /// Silence-gating of the audio handed to the transcription engine.
    case compaction
    case transcription
    case diarization
    /// `TranscriptFusion`: text spans + speaker turns → attributed segments.
    case fusion
    case correction
}

/// How a stage finished.
///
/// `skipped` and `degraded` are kept apart on purpose: a stage the user never
/// asked for is not a warning, while a requested stage that stepped down to a
/// weaker engine or a synthetic result is one, even though both produce a
/// usable transcript.
public enum PipelineStageOutcome: String, Codable, Sendable {
    /// Ran as requested and produced its intended result.
    case succeeded
    /// Produced a usable result, but not the requested one — a fallback
    /// engine, a fallback input, or synthetic output.
    case degraded
    /// Deliberately not run, because nothing requested it.
    case skipped
    /// Produced no usable result. A stage whose failure aborts the whole run
    /// throws instead of being recorded; this is for the stages that can fail
    /// and still let the run finish.
    case failed
}

/// Why a stage did not simply succeed. Closed vocabulary so the reason is
/// stable enough to branch on (H5 PR 13's stage-specific retry actions) and
/// safe to persist and export.
public enum PipelineStageReason: String, Codable, Sendable {
    /// Nothing requested this stage (engine set to none / feature off).
    case notRequested
    /// Requested, but the user has not consented to the model download it
    /// needs, so the selection stepped down instead of downloading.
    case notConsented
    /// Requested, but the engine is not available in this build or on this
    /// device.
    case engineUnavailable
    /// The engine's models could not be prepared (download/compile failure).
    case modelPreparationFailed
    /// The engine ran and failed. Its own error is intentionally not carried.
    case engineFailed
    /// The stage found nothing to work on (no speech, no eligible segment).
    case noInput
    /// The engine ran without reaching a conclusion, so the caller's own input
    /// was kept — a language detector returning the hint it was given.
    case detectionInconclusive
    /// Stage output was replaced by a single synthetic turn spanning the whole
    /// recording — not a genuine one-speaker result.
    case syntheticSingleTurn
    /// Fell back to the unprocessed audio for this stage's input.
    case originalAudioUsed
    /// No usable provider for a stage that needs one (missing key, unusable
    /// on-device model).
    case providerUnavailable
}

/// The outcome of one stage, including which engine was asked for versus which
/// one actually ran.
public struct PipelineStageReport: Codable, Sendable, Equatable, Identifiable {
    public var stage: PipelineStage
    public var outcome: PipelineStageOutcome
    /// `rawValue` of the engine the configuration selected, or `nil` for a
    /// stage with no engine axis (fusion, compaction).
    public var requestedEngine: String?
    /// `rawValue` of the engine that ran. `nil` when nothing ran.
    public var effectiveEngine: String?
    public var reason: PipelineStageReason?

    public var id: PipelineStage { stage }

    /// Whether the engine that ran is not the one that was requested.
    public var fellBack: Bool {
        guard let requestedEngine, let effectiveEngine else { return false }
        return requestedEngine != effectiveEngine
    }

    /// Whether this stage is something the user should be told about — the
    /// distinction the old boolean warning could not express.
    public var isWarning: Bool {
        outcome == .degraded || outcome == .failed
    }

    public init(
        stage: PipelineStage,
        outcome: PipelineStageOutcome,
        requestedEngine: String? = nil,
        effectiveEngine: String? = nil,
        reason: PipelineStageReason? = nil
    ) {
        self.stage = stage
        self.outcome = outcome
        self.requestedEngine = requestedEngine
        self.effectiveEngine = effectiveEngine
        self.reason = reason
    }
}

/// The aggregate of one run's stage reports, persisted beside the transcript so
/// "completed with warnings" is durable rather than re-derived from whatever
/// happens to still be in the log.
public struct PipelineReport: Codable, Sendable, Equatable {
    /// Bumped when a stored report's meaning changes. Unknown future versions
    /// are readable as long as the fields decode; consumers should check this
    /// before interpreting `stages` as exhaustive.
    public static let currentVersion = 1

    public var version: Int
    /// Stage reports in the order they were recorded (execution order).
    public var stages: [PipelineStageReport]

    public init(version: Int = PipelineReport.currentVersion, stages: [PipelineStageReport] = []) {
        self.version = version
        self.stages = stages
    }

    public subscript(stage: PipelineStage) -> PipelineStageReport? {
        stages.first { $0.stage == stage }
    }

    /// Stages the user should be told about, in execution order.
    public var warnings: [PipelineStageReport] {
        stages.filter { $0.isWarning }
    }

    public var hasWarnings: Bool { !warnings.isEmpty }

    /// The run's overall outcome: the worst stage outcome, with `skipped`
    /// treated as a non-event.
    public var overall: PipelineStageOutcome {
        if stages.contains(where: { $0.outcome == .failed }) { return .failed }
        if stages.contains(where: { $0.outcome == .degraded }) { return .degraded }
        return .succeeded
    }
}

/// Accumulates stage reports during a run.
///
/// A plain mutating value, not a lock or an actor: the orchestrator records
/// from its own task, and the two stages that run concurrently
/// (transcription and diarization) return their reports as values that are
/// merged once both are awaited, so there is no shared mutable state to
/// protect.
public struct PipelineReportBuilder: Sendable {
    private var stages: [PipelineStageReport] = []

    public init() {}

    /// Record one stage. A second record for the same stage replaces the
    /// first, keeping its position, so a stage that only learns its outcome
    /// later can overwrite a provisional entry.
    public mutating func record(_ report: PipelineStageReport) {
        if let index = stages.firstIndex(where: { $0.stage == report.stage }) {
            stages[index] = report
        } else {
            stages.append(report)
        }
    }

    public mutating func record(
        _ stage: PipelineStage,
        _ outcome: PipelineStageOutcome,
        requested: String? = nil,
        effective: String? = nil,
        reason: PipelineStageReason? = nil
    ) {
        record(PipelineStageReport(
            stage: stage,
            outcome: outcome,
            requestedEngine: requested,
            effectiveEngine: effective,
            reason: reason
        ))
    }

    public mutating func record(contentsOf reports: [PipelineStageReport]) {
        for report in reports { record(report) }
    }

    public var report: PipelineReport {
        PipelineReport(stages: stages)
    }
}
