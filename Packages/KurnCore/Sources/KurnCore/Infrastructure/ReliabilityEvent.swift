//
//  ReliabilityEvent.swift
//  KurnCore
//
//  A safe, content-free vocabulary for describing what happened during a
//  long-running or fallible operation (a document generation run, a
//  transcription chunk, a provider request), independent of any particular
//  operation's own ad hoc logging. Safety is structural: no field here can
//  hold raw error text, transcript content, a meeting title, or a URL, so a
//  caller cannot accidentally leak private content through this seam the
//  way a stray `localizedDescription` interpolation could.
//
//  This is the "operation IDs, safe event vocabulary" half of the
//  reliability track's first step (see docs/roadmap.md, "Baseline and
//  seams"); persisting these events for an on-device health screen is a
//  later phase (H9) — this type only standardizes what gets logged today.
//
//  KurnCore has no `os` dependency (it needs to build on Linux), so, like
//  `TranscriptQualityFilter.logHandler`, this exposes a handler seam instead
//  of logging directly; the app wires it to `AppLog` once at launch.
//

import Foundation

/// A short, opaque identifier for one run of an operation, threaded through
/// every event that run produces so they can be correlated in a log stream.
public struct OperationID: Hashable, Sendable, CustomStringConvertible {
    public let value: String

    /// Generates a fresh id, matching the `String(UUID().uuidString.prefix(8))`
    /// convention several call sites (e.g. `DocumentGenerationService`) already
    /// use for their own ad hoc `runID`.
    public init() {
        value = String(UUID().uuidString.prefix(8))
    }

    /// Wraps an existing identifier, e.g. one produced by an older call site
    /// during migration.
    public init(_ value: String) {
        self.value = value
    }

    public var description: String { value }
}

/// One point-in-time fact about an operation's progress: it started, it
/// succeeded, it failed, it was cancelled, or it is being retried.
public struct ReliabilityEvent: Sendable {
    public enum Outcome: String, Sendable {
        case started
        case succeeded
        case failed
        case cancelled
        case retried
    }

    /// Correlates every event from one run of `operation`.
    public let operationID: OperationID
    /// A free-text label for the kind of operation, e.g. "document_generation".
    /// Never user content — a fixed string each call site chooses once.
    public let operation: String
    /// Which step within the operation this event describes, e.g.
    /// "validation", "provider", "persistence". Empty when the operation has
    /// no meaningful stage breakdown.
    public let stage: String
    public let outcome: Outcome
    /// Zero-based attempt count; non-zero only for `.retried`/a retried
    /// `.failed`/`.succeeded`.
    public let attempt: Int
    public let elapsedSeconds: TimeInterval?
    /// A content-free diagnostic code, typically `AppError.logCode` — never
    /// `localizedDescription` or any other raw, potentially private string.
    public let code: String?

    public init(
        operationID: OperationID,
        operation: String,
        stage: String = "",
        outcome: Outcome,
        attempt: Int = 0,
        elapsedSeconds: TimeInterval? = nil,
        code: String? = nil
    ) {
        self.operationID = operationID
        self.operation = operation
        self.stage = stage
        self.outcome = outcome
        self.attempt = attempt
        self.elapsedSeconds = elapsedSeconds
        self.code = code
    }

    /// A single-line, content-free rendering safe to hand to `os_log` (or any
    /// future export) without further redaction.
    public var logLine: String {
        var parts = ["\(operation): \(outcome.rawValue)", "run=\(operationID)"]
        if !stage.isEmpty {
            parts.append("stage=\(stage)")
        }
        if attempt > 0 {
            parts.append("attempt=\(attempt)")
        }
        if let code {
            parts.append("code=\(code)")
        }
        if let elapsedSeconds {
            parts.append(String(format: "elapsed=%.2fs", elapsedSeconds))
        }
        return parts.joined(separator: " ")
    }
}

/// The single place a `ReliabilityEvent` is reported. Mirrors
/// `TranscriptQualityFilter.logHandler`'s shape: `nonisolated(unsafe)` because
/// it is set exactly once at launch, before any operation can run, and never
/// mutated afterward.
public enum ReliabilityLog {
    public nonisolated(unsafe) static var handler: (@Sendable (ReliabilityEvent) -> Void)?

    public static func record(_ event: ReliabilityEvent) {
        handler?(event)
    }
}
