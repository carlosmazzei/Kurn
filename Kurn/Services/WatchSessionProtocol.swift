//
//  WatchSessionProtocol.swift
//  Kurn
//
//  The phone↔watch WCSession wire contract: the dictionary keys and string
//  values exchanged in application context and messages, plus the shared
//  `WatchCommand` type itself. Both sides used to type these literals (and
//  `WatchCommand`) independently in per-target copies of this file, so a
//  rename on one side could silently break the remote control with no
//  compiler help.
//
//  H8 PR 20: this is now the single source, compiled into both the `Kurn`
//  and `KurnWatch` targets from this one location — the same
//  dual-target-membership pattern `Kurn/Infrastructure/RecordingActivityAttributes.swift`
//  already uses to share one file between `Kurn` and
//  `KurnLiveActivityExtension` (see that file's header), wired via an
//  explicit `Kurn.xcodeproj/project.pbxproj` Sources entry on the `KurnWatch`
//  target rather than that target's usual file-system-synchronized group.
//  There is now exactly one copy of `WatchCommand`/`WatchSessionKey` to keep
//  in sync with itself.
//

import Foundation

/// Command watch → phone.
enum WatchCommand: String, Sendable {
    case pause
    case resume
    case stop
    case highlight
}

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
    /// Number of highlights marked so far this recording, phone → watch.
    static let highlightCount = "highlightCount"
    /// Command reply: whether the phone handled the command.
    static let ok = "ok"
    /// Command reply: failure reason (see `WatchSessionReplyError`).
    static let error = "error"
    /// Unique ID per command send, watch → phone (H8 PR 20). Lets the phone
    /// recognize a redelivered duplicate — the watch retrying after a lost
    /// reply — and reply with the cached outcome instead of pausing,
    /// stopping, or marking a highlight a second time for one user action.
    static let commandID = "commandID"
    /// Command reply: which lifecycle phase the phone actually reached
    /// before replying (H8 PR 20; see `WatchAckPhase`).
    static let ackPhase = "ackPhase"
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

/// How far the phone got before replying to a Watch command (H8 PR 20, item
/// 7's "acknowledgements ... for received, state-changed, and
/// durably-finalized"). Every `RecordingCommandRouter` handler in this app
/// runs synchronously to completion — including `stop`'s file finalization —
/// before its caller learns the outcome, so a single reply carrying the
/// phase actually reached covers all three cases without a multi-message
/// round trip.
enum WatchAckPhase: String {
    /// The phone received the message but could not act on it — no
    /// recognized command, or no active recorder session to apply it to.
    case received
    /// The recorder's in-memory state changed (pause/resume/highlight, or a
    /// stop whose capture ended but whose file didn't cleanly finalize).
    case stateChanged
    /// The recording was durably finalized to disk (stop only).
    case finalized
}
