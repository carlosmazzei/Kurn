//
//  RecordingSurfacePayloads.swift
//  Kurn
//
//  What the recorder publishes to its two glanceable surfaces, and how a
//  Watch command is read and answered. `LockScreenRecordingController`
//  (ActivityKit) and `PhoneSessionController` (WatchConnectivity) only hand
//  these values to their frameworks, which a test cannot drive; the wire
//  contract itself is decided here, where it can be tested.
//

import Foundation

enum RecordingSurfacePayloads {

    // MARK: - Live Activity

    /// Anything but an active recording reads as paused on the Lock Screen,
    /// including the final `idle` state an ending activity is given.
    static func activityState(
        for state: AudioRecorderService.State,
        elapsed: TimeInterval,
        highlightCount: Int,
        now: Date = Date()
    ) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            isPaused: state != .recording,
            elapsed: elapsed,
            referenceDate: now,
            highlightCount: highlightCount
        )
    }

    // MARK: - Watch application context

    static func watchState(_ state: AudioRecorderService.State) -> String {
        switch state {
        case .idle: return WatchSessionState.idle
        case .recording: return WatchSessionState.recording
        case .paused: return WatchSessionState.paused
        }
    }

    static func watchContext(
        state: AudioRecorderService.State,
        meetingTitle: String,
        accumulatedElapsed: TimeInterval,
        referenceDate: Date,
        isAvailable: Bool,
        highlightCount: Int
    ) -> [String: Any] {
        [
            WatchSessionKey.state: watchState(state),
            WatchSessionKey.meetingTitle: meetingTitle,
            WatchSessionKey.referenceDate: referenceDate,
            WatchSessionKey.accumulatedElapsed: accumulatedElapsed,
            WatchSessionKey.isAvailable: isAvailable,
            WatchSessionKey.highlightCount: highlightCount
        ]
    }

    /// The context that tells the Watch no recording is running.
    static func endedWatchContext(now: Date = Date()) -> [String: Any] {
        watchContext(
            state: .idle,
            meetingTitle: "",
            accumulatedElapsed: 0,
            referenceDate: now,
            isAvailable: false,
            highlightCount: 0
        )
    }

    // MARK: - Watch commands

    struct DecodedCommand: Equatable, Sendable {
        var command: WatchCommand
        var commandID: String
    }

    /// The command a Watch message carries, or `nil` when it names none this
    /// build knows. A message without a `commandID` can only come from an
    /// older paired Watch build; it gets a fresh ID — never a replay match —
    /// so dedup simply doesn't engage rather than failing closed.
    static func decodeCommand(
        _ message: [String: Any],
        freshID: () -> String = { UUID().uuidString }
    ) -> DecodedCommand? {
        guard let raw = message[WatchSessionKey.command] as? String,
              let command = WatchCommand(rawValue: raw) else { return nil }
        let commandID = (message[WatchSessionKey.commandID] as? String) ?? freshID()
        return DecodedCommand(command: command, commandID: commandID)
    }

    static func unknownCommandReply() -> [String: Any] {
        [
            WatchSessionKey.ok: false,
            WatchSessionKey.error: WatchSessionReplyError.unknownCommand,
            WatchSessionKey.ackPhase: WatchAckPhase.received.rawValue
        ]
    }

    static func commandReply(handled: Bool, phase: WatchAckPhase) -> [String: Any] {
        guard handled else {
            return [
                WatchSessionKey.ok: false,
                WatchSessionKey.error: WatchSessionReplyError.noActiveRecording,
                WatchSessionKey.ackPhase: phase.rawValue
            ]
        }
        return [WatchSessionKey.ok: true, WatchSessionKey.ackPhase: phase.rawValue]
    }
}
