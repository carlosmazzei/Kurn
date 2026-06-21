//
//  RecordingCommandRouter.swift
//  MeetSync
//
//  Routes Live Activity deep links and Watch commands back to the active
//  in-app recorder. The recorder owns the real state changes; Live Activity
//  buttons and the Watch app only request an action from the currently
//  running recorder session.
//

import Foundation

/// Mirrors the command set the Watch app can send over WatchConnectivity.
/// Duplicated (not shared) on the watchOS target since the two targets don't
/// share source files.
enum WatchCommand: String {
    case pause
    case resume
    case stop
}

@MainActor
final class RecordingCommandRouter {
    static let shared = RecordingCommandRouter()

    private var onTogglePause: (() -> Void)?
    private var onPause: (() -> Void)?
    private var onResume: (() -> Void)?
    private var onStop: (() -> Void)?

    private init() {}

    func register(
        onTogglePause: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.onTogglePause = onTogglePause
        self.onPause = onPause
        self.onResume = onResume
        self.onStop = onStop
    }

    func unregister() {
        onTogglePause = nil
        onPause = nil
        onResume = nil
        onStop = nil
    }

    func handle(_ url: URL) {
        guard url.scheme == "meetsync", url.host == "recording" else { return }

        switch url.path {
        case "/toggle":
            onTogglePause?()
        case "/stop":
            onStop?()
        default:
            break
        }
    }

    /// Apply a command issued from the Watch app. Returns false if no
    /// recorder session is currently registered to handle it.
    @discardableResult
    func handleWatchCommand(_ command: WatchCommand) -> Bool {
        switch command {
        case .pause:
            guard let onPause else { return false }
            onPause()
        case .resume:
            guard let onResume else { return false }
            onResume()
        case .stop:
            guard let onStop else { return false }
            onStop()
        }
        return true
    }
}
