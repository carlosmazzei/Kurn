//
//  RecordingCommandRouter.swift
//  Kurn
//
//  Routes Live Activity deep links and Watch commands back to the active
//  in-app recorder. The recorder owns the real state changes; Live Activity
//  buttons and the Watch app only request an action from the currently
//  running recorder session.
//

import Foundation

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

    private init() {}

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
    }

    func unregister() {
        onTogglePause = nil
        onPause = nil
        onResume = nil
        onStop = nil
        onHighlight = nil
        recentCommands.removeAll()
    }

    func handle(_ url: URL) {
        guard url.scheme == "kurn", url.host == "recording" else { return }

        switch url.path {
        case "/toggle":
            AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: Live Activity toggle received")
            onTogglePause?()
        case "/stop":
            AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: Live Activity stop received")
            _ = onStop?()
        case "/highlight":
            AppLog.recorderUI.atNotice.notice("RecordingCommandRouter: Live Activity highlight received")
            onHighlight?()
        default:
            break
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
