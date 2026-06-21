//
//  WatchConnectivityManager.swift
//  MeetSyncWatch
//
//  Watch side of the remote control: receives recorder state pushed from the
//  iPhone via WCSession application context, and sends pause/resume/stop
//  commands back. Mirrors PhoneSessionController on the iOS target.
//

import Foundation
import Observation
import WatchConnectivity

/// Mirrors RecordingCommandRouter's command set on the iOS target.
/// Duplicated rather than shared since the two targets don't share sources.
enum WatchCommand: String {
    case pause
    case resume
    case stop
}

enum RemoteRecordingState: Equatable {
    case idle
    case recording(meetingTitle: String, referenceDate: Date, accumulatedElapsed: TimeInterval)
    case paused(meetingTitle: String, accumulatedElapsed: TimeInterval)
}

@MainActor
@Observable
final class WatchConnectivityManager: NSObject {
    private(set) var state: RemoteRecordingState = .idle
    /// True once the iPhone has reported a recording session exists to control.
    private(set) var isAvailable = false
    /// Normalized 0...1 level mirrored from the iPhone, best-effort.
    private(set) var level: Float = 0
    /// Set when the last command failed to reach the iPhone.
    private(set) var lastCommandFailed = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @discardableResult
    func send(_ command: WatchCommand) async -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            lastCommandFailed = true
            return false
        }
        let ok = await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(
                ["command": command.rawValue],
                replyHandler: { reply in
                    continuation.resume(returning: (reply["ok"] as? Bool) ?? false)
                },
                errorHandler: { _ in
                    continuation.resume(returning: false)
                }
            )
        }
        lastCommandFailed = !ok
        return ok
    }

    private func applyContext(_ context: [String: Any]) {
        let isAvailable = (context["isAvailable"] as? Bool) ?? false
        let rawState = (context["state"] as? String) ?? "idle"
        let meetingTitle = (context["meetingTitle"] as? String) ?? ""
        let referenceDate = (context["referenceDate"] as? Date) ?? Date()
        let accumulatedElapsed = (context["accumulatedElapsed"] as? TimeInterval) ?? 0

        self.isAvailable = isAvailable
        switch rawState {
        case "recording":
            state = .recording(
                meetingTitle: meetingTitle,
                referenceDate: referenceDate,
                accumulatedElapsed: accumulatedElapsed
            )
        case "paused":
            state = .paused(meetingTitle: meetingTitle, accumulatedElapsed: accumulatedElapsed)
            level = 0
        default:
            state = .idle
            level = 0
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.applyContext(context)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.applyContext(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let level = message["level"] as? Float else { return }
        Task { @MainActor in
            self.level = level
        }
    }
}
