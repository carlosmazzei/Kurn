//
//  AppLog.swift
//  Kurn
//
//  Lightweight access to `os.Logger` so we can trace runtime behavior in
//  Console.app / Xcode's console. Filter by subsystem `ai.kurn.app` or by
//  the category (e.g. "Recorder") to follow a single subsystem's flow.
//
//  Logging is on by default. Set `AppLog.isEnabled = false` (e.g. from a debug
//  menu) to silence every category at runtime, or launch with the
//  `KURN_LOG=0` environment variable to start with logging disabled. When
//  disabled, the categories resolve to a no-op `Logger(.disabled)`.
//

import Foundation
import os

enum AppLog {
    private static let subsystem = "ai.kurn.app"

    /// Master switch for all app logging. Defaults to enabled unless
    /// `KURN_LOG` is set to "0"/"false" at launch.
    nonisolated(unsafe) static var isEnabled: Bool = {
        if let raw = ProcessInfo.processInfo.environment["KURN_LOG"] {
            return raw != "0" && raw.lowercased() != "false"
        }
        return true
    }()

    private static let recorderLogger = Logger(subsystem: subsystem, category: "Recorder")
    private static let recorderUILogger = Logger(subsystem: subsystem, category: "RecorderUI")
    private static let transcriptionLogger = Logger(subsystem: subsystem, category: "Transcription")
    /// Shared no-op logger used while logging is disabled.
    private static let disabled = Logger(.disabled)

    /// Audio capture lifecycle (engine, session, metering).
    static var recorder: Logger { isEnabled ? recorderLogger : disabled }
    /// Recorder view-model / UI state transitions.
    static var recorderUI: Logger { isEnabled ? recorderUILogger : disabled }
    /// Transcription pipeline (preprocessing, chunking, engines, fusion, summary).
    static var transcription: Logger { isEnabled ? transcriptionLogger : disabled }
}
