//
//  WatchSessionProtocol.swift
//  KurnWatch
//
//  The phone↔watch WCSession wire contract: the dictionary keys and string
//  values exchanged in application context and messages. Both sides typed these
//  literals independently, so a rename on one side would silently break the
//  remote control with no compiler help. Centralizing them here (and reading the
//  named constants at every call site) removes the intra-target drift.
//
//  Duplicated (not shared) because the app and watchOS targets don't share
//  source files — the app copy (`Kurn/Services/WatchSessionProtocol.swift`)
//  must stay byte-for-byte identical. Keep both copies in sync.
//

import Foundation

/// Keys used in the WCSession application context and messages.
enum WatchSessionKey {
    /// Command name sent watch → phone (`WatchCommand.rawValue`).
    static let command = "command"
    /// Recorder state string, phone → watch (see `WatchSessionState`).
    static let state = "state"
    static let meetingTitle = "meetingTitle"
    static let referenceDate = "referenceDate"
    static let accumulatedElapsed = "accumulatedElapsed"
    static let isAvailable = "isAvailable"
    /// Normalized 0...1 audio level, phone → watch.
    static let level = "level"
    /// Command reply: whether the phone handled the command.
    static let ok = "ok"
    /// Command reply: failure reason (see `WatchSessionReplyError`).
    static let error = "error"
}

/// Values carried by `WatchSessionKey.state`.
enum WatchSessionState {
    static let idle = "idle"
    static let recording = "recording"
    static let paused = "paused"
}

/// Values carried by `WatchSessionKey.error` in a command reply.
enum WatchSessionReplyError {
    static let unknownCommand = "unknown_command"
    static let noActiveRecording = "no_active_recording"
}
