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
        isAvailable: Bool
    ) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let context: [String: Any] = [
            "state": stateString(state),
            "meetingTitle": meetingTitle,
            "referenceDate": referenceDate,
            "accumulatedElapsed": accumulatedElapsed,
            "isAvailable": isAvailable
        ]
        try? session.updateApplicationContext(context)
    }

    func notifyEnded() {
        pushState(
            state: .idle,
            meetingTitle: "",
            accumulatedElapsed: 0,
            referenceDate: Date(),
            isAvailable: false
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
            session.sendMessage(["level": level], replyHandler: nil, errorHandler: nil)
        }
    }

    private func stateString(_ state: AudioRecorderService.State) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .paused: return "paused"
        }
    }
}

extension PhoneSessionController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let raw = message["command"] as? String, let command = WatchCommand(rawValue: raw) else {
            replyHandler(["ok": false, "error": "unknown_command"])
            return
        }
        let reply = WatchCommandReplyHandler(reply: replyHandler)
        Task {
            let handled = await MainActor.run {
                RecordingCommandRouter.shared.handleWatchCommand(command)
            }
            reply.call(handled ? ["ok": true] : ["ok": false, "error": "no_active_recording"])
        }
    }
}
