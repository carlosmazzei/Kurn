//
//  AppLog.swift
//  Kurn
//
//  Lightweight access to `os.Logger` so we can trace runtime behavior in
//  Console.app / Xcode's console. Filter by subsystem `ai.kurn.app` or by
//  the category (e.g. "Recorder") to follow a single subsystem's flow.
//
//  Logging is leveled. Every call site declares a severity (`debug`, `info`,
//  `notice`, `error`, `fault`) and `AppLog.minimumLevel` gates which ones are
//  actually emitted. The user controls the level from Settings (persisted via
//  `AppSettings.logLevel`); `LogLevel.off` silences everything.
//
//  At launch the level defaults to `.notice`, or to whatever `KURN_LOG_LEVEL`
//  / `KURN_LOG` specify:
//    * `KURN_LOG=0` / `KURN_LOG=false`  -> `.off`
//    * `KURN_LOG_LEVEL=debug|info|notice|error|off`
//

import Foundation
import os

/// User-facing logging verbosity. Cases are ordered from least to most verbose;
/// `minimumLevel` keeps every message whose severity is at least as important as
/// the selected level (so `.info` keeps info, notice, error, and fault).
enum LogLevel: String, Codable, Sendable, CaseIterable, Identifiable, Comparable {
    /// No logging at all.
    case off
    /// Failures only (`error` + `fault`).
    case error
    /// Key lifecycle milestones and above (the default).
    case notice
    /// Informational details and above.
    case info
    /// Everything, including high-frequency / per-iteration traces.
    case debug

    var id: String { rawValue }

    /// Higher = more verbose. Used to compare a message's severity against the
    /// configured threshold.
    fileprivate var rank: Int {
        switch self {
        case .off: return 0
        case .error: return 1
        case .notice: return 2
        case .info: return 3
        case .debug: return 4
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }

    var displayName: String {
        switch self {
        case .off: return NSLocalizedString("log_level.off", comment: "Logging off")
        case .error: return NSLocalizedString("log_level.error", comment: "Errors only")
        case .notice: return NSLocalizedString("log_level.notice", comment: "Standard")
        case .info: return NSLocalizedString("log_level.info", comment: "Detailed")
        case .debug: return NSLocalizedString("log_level.debug", comment: "Verbose")
        }
    }
}

enum AppLog {
    private static let subsystem = "ai.kurn.app"

    /// Minimum severity that is actually emitted. Defaults from the environment
    /// at launch; `AppSettings` overrides it with the user's stored preference.
    nonisolated(unsafe) static var minimumLevel: LogLevel = Self.environmentDefaultLevel()

    /// Whether logging is on at all. Kept for call sites that want to skip
    /// expensive work before building a log message.
    static var isEnabled: Bool { minimumLevel != .off }

    /// True when a message at `level` should be emitted under the current
    /// `minimumLevel`.
    fileprivate static func allows(_ level: LogLevel) -> Bool {
        level.rank <= minimumLevel.rank && minimumLevel != .off
    }

    private static func environmentDefaultLevel() -> LogLevel {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["KURN_LOG_LEVEL"]?.lowercased(),
           let level = LogLevel(rawValue: raw) {
            return level
        }
        if let raw = env["KURN_LOG"] {
            return (raw == "0" || raw.lowercased() == "false") ? .off : .debug
        }
        return .notice
    }

    private static let recorderLogger = Logger(subsystem: subsystem, category: "Recorder")
    private static let recorderUILogger = Logger(subsystem: subsystem, category: "RecorderUI")
    private static let transcriptionLogger = Logger(subsystem: subsystem, category: "Transcription")

    /// Audio capture lifecycle (engine, session, metering).
    static let recorder = CategoryLogger(recorderLogger)
    /// Recorder view-model / UI state transitions.
    static let recorderUI = CategoryLogger(recorderUILogger)
    /// Transcription pipeline (preprocessing, chunking, engines, fusion, summary).
    static let transcription = CategoryLogger(transcriptionLogger)
}

/// Thin wrapper over `os.Logger` that gates each message by `AppLog.minimumLevel`
/// before forwarding it. The methods accept `OSLogMessage`, so call sites keep
/// using string interpolation with `privacy:` annotations exactly as before.
struct CategoryLogger: Sendable {
    private let logger: Logger

    init(_ logger: Logger) {
        self.logger = logger
    }

    /// High-frequency / per-iteration traces. Hidden unless the level is `.debug`.
    func debug(_ message: OSLogMessage) {
        guard AppLog.allows(.debug) else { return }
        logger.debug(message)
    }

    /// Informational details (formats, counts, timings).
    func info(_ message: OSLogMessage) {
        guard AppLog.allows(.info) else { return }
        logger.info(message)
    }

    /// Key lifecycle milestones. This is the default level for `log`.
    func notice(_ message: OSLogMessage) {
        guard AppLog.allows(.notice) else { return }
        logger.notice(message)
    }

    /// Alias for `notice`, matching `os.Logger`'s default `log` level.
    func log(_ message: OSLogMessage) {
        notice(message)
    }

    /// Recoverable failures.
    func error(_ message: OSLogMessage) {
        guard AppLog.allows(.error) else { return }
        logger.error(message)
    }

    /// Programmer errors / unexpected invariants. Emitted whenever logging is on.
    func fault(_ message: OSLogMessage) {
        guard AppLog.allows(.error) else { return }
        logger.fault(message)
    }
}
