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
    private var recentCommands: [(id: String, handled: Bool, phase: WatchAckPhase)] = []
    private let recentCommandCapacity = 20

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
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    /// Apply a Live Activity button (`RecordingControlIntent`). These used to
    /// arrive as `kurn://recording/...` deep links, which any app could open;
    /// an App Intent only reaches here from the Live Activity itself.
    func handle(_ action: RecordingControlAction) {
        AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: Live Activity \(action.rawValue, privacy: .public) received")
        switch action {
        case .togglePause:
            onTogglePause?()
        case .stop:
            _ = onStop?()
        case .highlight:
            onHighlight?()
        }
    }

    /// Apply a command issued from the Watch app, deduplicated by
    /// `commandID`. Returns whether a recorder session handled it and which
    /// lifecycle phase the phone actually reached.
    @discardableResult
    func handleWatchCommand(_ command: WatchCommand, commandID: String) -> (handled: Bool, phase: WatchAckPhase) {
        if let cached = recentCommands.first(where: { $0.id == commandID }) {
            AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: replaying cached result for duplicate Watch command \(commandID, privacy: .public)")
            return (cached.handled, cached.phase)
        }
        let result = performWatchCommand(command)
        recentCommands.append((commandID, result.handled, result.phase))
        if recentCommands.count > recentCommandCapacity {
            recentCommands.removeFirst(recentCommands.count - recentCommandCapacity)
        }
        return result
    }

    private func performWatchCommand(_ command: WatchCommand) -> (handled: Bool, phase: WatchAckPhase) {
        AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: Watch command received: \(command.rawValue, privacy: .public)")
        switch command {
        case .pause:
            guard let onPause else {
                AppLog.recorderUI.atError.error("RecordingCommandRouter: Watch pause ignored, no active session")
                return (false, .received)
            }
            onPause()
            return (true, .stateChanged)
        case .resume:
            guard let onResume else {
                AppLog.recorderUI.atError.error("RecordingCommandRouter: Watch resume ignored, no active session")
                return (false, .received)
            }
            onResume()
            return (true, .stateChanged)
        case .stop:
            guard let onStop else {
                AppLog.recorderUI.atError.error("RecordingCommandRouter: Watch stop ignored, no active session")
                return (false, .received)
            }
            let finalized = onStop()
            return (true, finalized ? .finalized : .stateChanged)
        case .highlight:
            guard let onHighlight else {
                AppLog.recorderUI.atError.error("RecordingCommandRouter: Watch highlight ignored, no active session")
                return (false, .received)
            }
            onHighlight()
            return (true, .stateChanged)
        }
    }
}
