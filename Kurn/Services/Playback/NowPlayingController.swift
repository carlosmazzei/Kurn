//
//  NowPlayingController.swift
//  Kurn
//
//  Publishes what is playing to the rest of the system, and accepts the system's
//  transport commands back.
//
//  The app declares `UIBackgroundModes: audio`, so playback continues when the
//  screen locks. Without this, it continues *invisibly*: nothing on the Lock
//  Screen, in Control Center, on the Dynamic Island, on AirPods stem presses, in
//  CarPlay, on the Watch's Now Playing, or on a steering-wheel button. For an app
//  whose recordings are most naturally listened to while driving or walking, that
//  is the difference between usable and not.
//
//  Two ownership rules keep this honest. `MPRemoteCommandCenter` is process-wide,
//  so handlers are registered on `activate` and *removed* on `deactivate` —
//  leaving them attached would let a torn-down player keep answering the Lock
//  Screen. And the elapsed time is pushed only on state changes, never on the
//  player's 0.1 s tick: `MPNowPlayingInfoCenter` extrapolates position from the
//  playback rate, so the ticks would be redundant IPC forty times a second.
//

import Foundation
import MediaPlayer

@MainActor
final class NowPlayingController {

    /// What the system's transport controls do. The player supplies these; this
    /// type never touches the player directly.
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var skip: (TimeInterval) -> Void
        var seek: (TimeInterval) -> Void
    }

    /// Matches the skip interval the in-app transport offers, and is what the
    /// Lock Screen renders inside the arrow glyphs.
    static let skipInterval: TimeInterval = 15

    private var handlers: Handlers?
    private var isActive = false

    // MARK: - Lifecycle

    func activate(handlers: Handlers) {
        self.handlers = handlers
        guard !isActive else { return }
        isActive = true

        let center = MPRemoteCommandCenter.shared()

        // Each handler hands the work to the main actor and answers `.success`
        // straight away. The alternative — `MainActor.assumeIsolated` — reads
        // better but *traps* if the system ever delivers a command off the main
        // thread, which is a crash on the Lock Screen in exchange for a return
        // value nothing acts on.
        _ = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlers?.play() }
            return .success
        }
        _ = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlers?.pause() }
            return .success
        }
        _ = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.handlers?.toggle() }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        _ = center.skipForwardCommand.addTarget { [weak self] event in
            // Read off the event before the hop: it is not `Sendable`, and the
            // system reuses it once the handler returns.
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Task { @MainActor in self?.handlers?.skip(interval) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        _ = center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipInterval
            Task { @MainActor in self?.handlers?.skip(-interval) }
            return .success
        }

        _ = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            Task { @MainActor in self?.handlers?.seek(position) }
            return .success
        }

        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] {
            command.isEnabled = true
        }
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        // A meeting recording is one item, not a queue. Left enabled, these would
        // render as skip buttons that do nothing.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    func deactivate() {
        handlers = nil
        // Only clear what we published. `stop()` runs on a player that was never
        // loaded too, and `nowPlayingInfo` is process-wide.
        guard isActive else { return }
        isActive = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
    }

    // MARK: - Metadata

    /// Push the current state. Call on load, play, pause, seek and rate changes —
    /// the system interpolates everything in between from `rate`.
    func update(
        title: String?,
        subtitle: String?,
        duration: TimeInterval,
        position: TimeInterval,
        rate: Float
    ) {
        guard isActive else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = Self.info(
            title: title,
            subtitle: subtitle,
            duration: duration,
            position: position,
            rate: rate
        )
    }

    /// The dictionary `update` publishes. Split out because it is the part with
    /// rules — empty metadata is omitted rather than sent blank, and the position
    /// is clamped — and the part a test can reach without a Lock Screen.
    static func info(
        title: String?,
        subtitle: String?,
        duration: TimeInterval,
        position: TimeInterval,
        rate: Float
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPMediaItemPropertyPlaybackDuration: max(0, duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(max(0, position), max(0, duration)),
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let title, !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if let subtitle, !subtitle.isEmpty {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        return info
    }
}
