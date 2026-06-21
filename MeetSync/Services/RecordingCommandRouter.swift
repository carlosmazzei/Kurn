//
//  RecordingCommandRouter.swift
//  MeetSync
//
//  Routes Live Activity deep links back to the active in-app recorder. The
//  recorder owns the real state changes; Live Activity buttons only request an
//  action from the currently running recorder session.
//

import Foundation

@MainActor
final class RecordingCommandRouter {
    static let shared = RecordingCommandRouter()

    private var onTogglePause: (() -> Void)?
    private var onStop: (() -> Void)?

    private init() {}

    func register(
        onTogglePause: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.onTogglePause = onTogglePause
        self.onStop = onStop
    }

    func unregister() {
        onTogglePause = nil
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
}
