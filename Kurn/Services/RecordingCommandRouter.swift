//
//  RecordingCommandRouter.swift
//  Kurn
//
//  Routes Live Activity button intents and Watch commands back to the active
//  in-app recorder. The recorder owns the real state changes; Live Activity
//  buttons and the Watch app only request an action from the currently
//  running recorder session.
//

import Foundation
import UIKit

@MainActor
final class RecordingCommandRouter {
    static let shared = RecordingCommandRouter()

    private var onTogglePause: (() -> Void)?
    private var onPause: (() -> Void)?
    private var onResume: (() -> Void)?
    /// Returns whether the recording was durably finalized to disk (`true`)
    /// or only reached a recovery-needed state (`false`) — `stopAndSave()`
    /// runs entirely synchronously (including file finalization), so this is
    /// known by the time the closure returns, not discovered later. Backs
    /// the Watch command reply's `WatchAckPhase` (H8 PR 20).
    private var onStop: (() -> Bool)?
    private var onHighlight: (() -> Void)?

    /// Recently handled Watch command IDs, oldest first, so a redelivered
    /// duplicate (the watch retrying after a lost reply) replays the cached
    /// outcome instead of pausing/stopping/highlighting a second time for
    /// one user action (H8 PR 20, item 7's "deduplication"). Bounded rather
    /// than time-based: commands are issued one at a time by hand, so a
    /// small fixed window comfortably covers any realistic retry without
    /// growing unbounded over a long recording.
    private struct WatchCommandResult {
        var handled: Bool
        var phase: WatchAckPhase
        var error: String?
    }

    private var recentCommands: [(id: String, result: WatchCommandResult)] = []
    private let recentCommandCapacity = 20

    /// Error attached to the most recent `handleWatchCommand` result — the
    /// tuple itself stays `(handled, phase)` for the dedup cache, so the one
    /// new failure kind (`.start` while already recording) reaches the reply
    /// through here.
    private(set) var lastCommandError: String?

    /// Test seams for the `.start` path: production reads the real app
    /// state and asks `RecordingLauncher` to queue a meeting.
    var isForeground: () -> Bool = { UIApplication.shared.applicationState == .active }
    var requestStart: () -> Bool = { RecordingLauncher.shared.requestAutoStart() }

    private var terminationObserver: NSObjectProtocol?

    private init() {}

    /// Stop and save the live recording because the process is about to end.
    /// iOS posts `willTerminateNotification` — with a few seconds to act — to
    /// an app still running in the background when the user swipes it away
    /// from the app switcher, which a recording app with the `audio`
    /// background mode is. Stopping here closes the `.m4a` (writing its
    /// sample table) and saves the row as `.ready`, so that common case needs
    /// no recovery at all. iOS does not always post it (a suspended or
    /// jetsammed process just dies); `CaptureJournal` covers those.
    func stopForTermination() {
        guard let onStop else { return }
        AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: app terminating, stopping the live recording")
        _ = onStop()
    }

    /// Whether a live recorder session currently has its handlers registered.
    /// Used to gate maintenance that must never run mid-recording (e.g. the
    /// foreground orphan sweep, which would otherwise treat the in-progress
    /// audio file — no `Recording` row yet — as an orphan).
    var hasActiveSession: Bool { onStop != nil }

    func register(
        onTogglePause: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onStop: @escaping () -> Bool,
        onHighlight: @escaping () -> Void
    ) {
        self.onTogglePause = onTogglePause
        self.onPause = onPause
        self.onResume = onResume
        self.onStop = onStop
        self.onHighlight = onHighlight
        observeTermination()
    }

    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            // UIKit posts it on the main thread; a nil queue runs the block
            // right there, before `post` returns and the process goes away.
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { RecordingCommandRouter.shared.stopForTermination() }
        }
    }

    func unregister() {
        onTogglePause = nil
        onPause = nil
        onResume = nil
        onStop = nil
        onHighlight = nil
        recentCommands.removeAll()
        lastCommandError = nil
        // Test seams back to production — a test that swapped them and tore
        // down its session can't leak the fake into the next test.
        isForeground = { UIApplication.shared.applicationState == .active }
        requestStart = { RecordingLauncher.shared.requestAutoStart() }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    /// Apply a Live Activity button (`RecordingControlIntent`). These used to
    /// arrive as `kurn://recording/...` deep links, which any app could open;
    /// an App Intent only reaches here from the Live Activity itself. Returns
    /// whether a live recorder session handled it, so the intent only
    /// reflects a pause on the Lock Screen when one actually happened.
    @discardableResult
    func handle(_ action: RecordingControlAction) -> Bool {
        AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: Live Activity \(action.rawValue, privacy: .public) received")
        switch action {
        case .togglePause:
            guard let onTogglePause else { return false }
            onTogglePause()
        case .stop:
            guard let onStop else { return false }
            _ = onStop()
        case .highlight:
            guard let onHighlight else { return false }
            onHighlight()
        }
        return true
    }

    /// Apply a command issued from the Watch app, deduplicated by
    /// `commandID`. Returns whether a recorder session handled it and which
    /// lifecycle phase the phone actually reached.
    @discardableResult
    func handleWatchCommand(_ command: WatchCommand, commandID: String) -> (handled: Bool, phase: WatchAckPhase) {
        if let cached = recentCommands.first(where: { $0.id == commandID }) {
            AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: replaying cached result for duplicate Watch command \(commandID, privacy: .public)")
            lastCommandError = cached.result.error
            return (cached.result.handled, cached.result.phase)
        }
        let result = performWatchCommand(command)
        lastCommandError = result.error
        recentCommands.append((commandID, result))
        if recentCommands.count > recentCommandCapacity {
            recentCommands.removeFirst(recentCommands.count - recentCommandCapacity)
        }
        return (result.handled, result.phase)
    }

    private func performWatchCommand(_ command: WatchCommand) -> WatchCommandResult {
        AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: Watch command received: \(command.rawValue, privacy: .public)")
        switch command {
        case .start:
            // Starting a recording from the wrist goes through the same
            // queue the Control Center intent uses: `RecordingLauncher`
            // creates the meeting and `RecordingSessionPresenter` starts
            // capture — but only while the app is foreground (or next
            // becomes it, hence the `.queued` acknowledgement).
            guard !hasActiveSession else {
                return WatchCommandResult(handled: false, phase: .received, error: WatchSessionReplyError.recordingAlreadyActive)
            }
            guard requestStart() else {
                return WatchCommandResult(handled: false, phase: .received, error: WatchSessionReplyError.noActiveRecording)
            }
            return WatchCommandResult(handled: true, phase: isForeground() ? .stateChanged : .queued, error: nil)
        case .pause:
            guard let onPause else {
                AppLog.recorderUI.atError.error("RecordingCommandRouter: Watch pause ignored, no active session")
                return WatchCommandResult(handled: false, phase: .received, error: WatchSessionReplyError.noActiveRecording)
            }
            onPause()
            return WatchCommandResult(handled: true, phase: .stateChanged, error: nil)
        case .resume:
            guard let onResume else {
                AppLog.recorderUI.atError.error("RecordingCommandRouter: Watch resume ignored, no active session")
                return WatchCommandResult(handled: false, phase: .received, error: WatchSessionReplyError.noActiveRecording)
            }
            onResume()
            return WatchCommandResult(handled: true, phase: .stateChanged, error: nil)
        case .stop:
            guard let onStop else {
                AppLog.recorderUI.atError.error("RecordingCommandRouter: Watch stop ignored, no active session")
                return WatchCommandResult(handled: false, phase: .received, error: WatchSessionReplyError.noActiveRecording)
            }
            let finalized = onStop()
            return WatchCommandResult(handled: true, phase: finalized ? .finalized : .stateChanged, error: nil)
        case .highlight:
            guard let onHighlight else {
                AppLog.recorderUI.atError.error("RecordingCommandRouter: Watch highlight ignored, no active session")
                return WatchCommandResult(handled: false, phase: .received, error: WatchSessionReplyError.noActiveRecording)
            }
            onHighlight()
            return WatchCommandResult(handled: true, phase: .stateChanged, error: nil)
        }
    }
}
