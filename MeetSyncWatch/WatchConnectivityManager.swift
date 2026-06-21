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
enum WatchCommand: String, Sendable {
    case pause
    case resume
    case stop
}

enum RemoteRecordingState: Equatable {
    case idle
    case recording(meetingTitle: String, referenceDate: Date, accumulatedElapsed: TimeInterval)
    case paused(meetingTitle: String, accumulatedElapsed: TimeInterval)
}

private struct WatchRecordingContext: Sendable {
    let isAvailable: Bool
    let rawState: String
    let meetingTitle: String
    let referenceDate: Date
    let accumulatedElapsed: TimeInterval

    init(_ context: [String: Any]) {
        isAvailable = (context["isAvailable"] as? Bool) ?? false
        rawState = (context["state"] as? String) ?? "idle"
        meetingTitle = (context["meetingTitle"] as? String) ?? ""
        referenceDate = (context["referenceDate"] as? Date) ?? Date()
        accumulatedElapsed = (context["accumulatedElapsed"] as? TimeInterval) ?? 0
    }
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

    private func applyContext(_ context: WatchRecordingContext) {
        self.isAvailable = context.isAvailable
        switch context.rawState {
        case "recording":
            state = .recording(
                meetingTitle: context.meetingTitle,
                referenceDate: context.referenceDate,
                accumulatedElapsed: context.accumulatedElapsed
            )
        case "paused":
            state = .paused(
                meetingTitle: context.meetingTitle,
                accumulatedElapsed: context.accumulatedElapsed
            )
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
        let context = WatchRecordingContext(session.receivedApplicationContext)
        Task { @MainActor in
            self.applyContext(context)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let context = WatchRecordingContext(applicationContext)
        Task { @MainActor in
            self.applyContext(context)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let level = message["level"] as? Float else { return }
        Task { @MainActor in
            self.level = level
        }
    }
}
