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
        push(RecordingSurfacePayloads.watchContext(
            state: state,
            meetingTitle: meetingTitle,
            accumulatedElapsed: accumulatedElapsed,
            referenceDate: referenceDate,
            isAvailable: isAvailable,
            highlightCount: highlightCount
        ))
    }

    func notifyEnded() {
        push(RecordingSurfacePayloads.endedWatchContext())
    }

    private func push(_ context: [String: Any]) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(context)
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
        guard let decoded = RecordingSurfacePayloads.decodeCommand(message) else {
            AppLog.recorderUI.atError.error("PhoneSessionController: received unrecognized Watch command")
            replyHandler(RecordingSurfacePayloads.unknownCommandReply())
            return
        }
        AppLog.recorderUI.atNotice.notice("PhoneSessionController: received Watch command \(decoded.command.rawValue, privacy: .public)")
        let reply = WatchCommandReplyHandler(reply: replyHandler)
        Task {
            let (handled, phase) = await MainActor.run {
                RecordingCommandRouter.shared.handleWatchCommand(decoded.command, commandID: decoded.commandID)
            }
            reply.call(RecordingSurfacePayloads.commandReply(handled: handled, phase: phase))
        }
    }
}
