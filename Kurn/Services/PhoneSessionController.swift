//
//  PhoneSessionController.swift
//  Kurn
//
//  iPhone side of the Watch remote control. Pushes recorder state to the
//  paired Watch via WCSession's application context (survives disconnects)
//  and forwards Watch-issued commands to RecordingCommandRouter, the same
//  dispatcher the Lock Screen Live Activity already uses.
//

import Foundation
import WatchConnectivity

private struct WatchCommandReplyHandler: @unchecked Sendable {
    let reply: ([String: Any]) -> Void

    func call(_ response: [String: Any]) {
        reply(response)
    }
}

@MainActor
final class PhoneSessionController: NSObject {
    static let shared = PhoneSessionController()

    /// Minimum spacing between level pushes to the Watch, to avoid flooding
    /// WatchConnectivity with a message on every 50ms metering tick.
    private let levelPushInterval: TimeInterval = 0.2
    private var lastLevelPushDate: Date?

    private override init() {
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func pushState(
        state: AudioRecorderService.State,
        meetingTitle: String,
        accumulatedElapsed: TimeInterval,
        referenceDate: Date,
        isAvailable: Bool,
        highlightCount: Int
    ) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let context: [String: Any] = [
            WatchSessionKey.state: stateString(state),
            WatchSessionKey.meetingTitle: meetingTitle,
            WatchSessionKey.referenceDate: referenceDate,
            WatchSessionKey.accumulatedElapsed: accumulatedElapsed,
            WatchSessionKey.isAvailable: isAvailable,
            WatchSessionKey.highlightCount: highlightCount
        ]
        try? session.updateApplicationContext(context)
    }

    func notifyEnded() {
        pushState(
            state: .idle,
            meetingTitle: "",
            accumulatedElapsed: 0,
            referenceDate: Date(),
            isAvailable: false,
            highlightCount: 0
        )
    }

    func pushLevel(_ level: Float) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }

        let now = Date()
        if let last = lastLevelPushDate, now.timeIntervalSince(last) < levelPushInterval { return }
        lastLevelPushDate = now

        // Send off the main thread: this runs from the recorder's 20 Hz metering
        // tick, and WatchConnectivity IPC on the main thread caused periodic UI
        // hitches. Capturing only `level` (Sendable) keeps it data-race free.
        Self.sendLevelOffMain(level)
    }

    private nonisolated static func sendLevelOffMain(_ level: Float) {
        DispatchQueue.global(qos: .utility).async {
            let session = WCSession.default
            guard session.activationState == .activated, session.isReachable else { return }
            session.sendMessage([WatchSessionKey.level: level], replyHandler: nil, errorHandler: nil)
        }
    }

    private func stateString(_ state: AudioRecorderService.State) -> String {
        switch state {
        case .idle: return WatchSessionState.idle
        case .recording: return WatchSessionState.recording
        case .paused: return WatchSessionState.paused
        }
    }
}

extension PhoneSessionController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // H8 PR 20, item 7's "reconcile from application context after
        // reconnect": if this phone process has no live recorder session
        // registered, any "recording"/"paused" context WCSession is still
        // holding from before is stale — a live session never survives
        // process termination, so a fresh launch (including one after a kill
        // mid-recording) always starts with `hasActiveSession == false`.
        // Correcting the Watch's picture here, right on (re)activation,
        // rather than waiting for the next real state change (which may
        // never come if the user doesn't start another recording) is what
        // keeps a phantom "still recording" from persisting on the Watch
        // indefinitely.
        guard activationState == .activated else { return }
        Task { @MainActor in
            guard !RecordingCommandRouter.shared.hasActiveSession else { return }
            PhoneSessionController.shared.notifyEnded()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let raw = message[WatchSessionKey.command] as? String, let command = WatchCommand(rawValue: raw) else {
            AppLog.recorderUI.atError.error("PhoneSessionController: received unrecognized Watch command")
            replyHandler([
                WatchSessionKey.ok: false,
                WatchSessionKey.error: WatchSessionReplyError.unknownCommand,
                WatchSessionKey.ackPhase: WatchAckPhase.received.rawValue
            ])
            return
        }
        // A commandID-less message can only come from an older paired Watch
        // app build; fall back to a fresh ID (never a replay match) so
        // dedup simply doesn't engage rather than failing closed.
        let commandID = (message[WatchSessionKey.commandID] as? String) ?? UUID().uuidString
        AppLog.recorderUI.atNotice.notice("PhoneSessionController: received Watch command \(raw, privacy: .public)")
        let reply = WatchCommandReplyHandler(reply: replyHandler)
        Task {
            let (handled, phase) = await MainActor.run {
                RecordingCommandRouter.shared.handleWatchCommand(command, commandID: commandID)
            }
            reply.call(handled
                ? [WatchSessionKey.ok: true, WatchSessionKey.ackPhase: phase.rawValue]
                : [
                    WatchSessionKey.ok: false,
                    WatchSessionKey.error: WatchSessionReplyError.noActiveRecording,
                    WatchSessionKey.ackPhase: phase.rawValue
                ])
        }
    }
}
