//
//  AudioPlayerService.swift
//  Kurn
//
//  AVAudioPlayer wrapper for transcript-synced playback. Exposes observable
//  position/duration and supports seeking to a segment timestamp.
//
//  Beyond the player itself this owns the two things that make playback behave
//  like a media app rather than a sound effect: the system transport surfaces
//  (`NowPlayingController`) and audio-session events. The recorder has handled
//  interruptions and route changes since it was written; the player did not, so
//  an incoming call left `isPlaying` true over a stopped `AVAudioPlayer` — the
//  scrubber frozen, the button showing pause, and nothing resuming afterwards.
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlayerService: NSObject {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// File name currently loaded, so the UI can highlight the active recording.
    private(set) var loadedFileName: String?
    /// Current playback speed multiplier (e.g. 0.5, 1.0, 1.5, 2.0). Persists
    /// across loads/seeks so the user's choice sticks for the session.
    private(set) var playbackRate: Float = 1.0
    /// Whether the file currently open is the enhanced copy rather than the
    /// original.
    private(set) var isPlayingEnhanced = false

    /// Speeds the user can cycle through, mirroring WhatsApp's voice-note control.
    static let rateOptions: [Float] = [1.0, 1.5, 2.0, 0.5]

    /// How far the skip controls move, in both the app and the Lock Screen.
    static var skipInterval: TimeInterval { NowPlayingController.skipInterval }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let nowPlaying = NowPlayingController()
    private var nowPlayingTitle: String?
    private var nowPlayingSubtitle: String?
    /// Whether playback was interrupted mid-play, so `.shouldResume` knows there
    /// is something to resume.
    private var wasPlayingBeforeInterruption = false

    override init() {
        super.init()
        registerNotifications()
    }

    /// Load a recording, optionally its enhanced listening copy.
    ///
    /// `loadedFileName` always reports the **logical** recording name, never the
    /// physical file opened. The whole UI keys row-to-player identity off
    /// `player.loadedFileName == recording.fileName`, so reporting the enhanced
    /// copy's location here would make the scrubber vanish and the play/pause
    /// button stop tracking — the variant is an internal detail of which URL to
    /// open, not a different recording.
    ///
    /// Reuses the existing player only when both the recording *and* the variant
    /// match; comparing the name alone would silently ignore a variant switch.
    ///
    /// `title`/`subtitle` are what the Lock Screen, CarPlay and the Watch show.
    /// They are optional so playback still works if a caller has nothing to say,
    /// and are remembered across a `reload` into the other variant.
    func load(
        fileName: String,
        title: String? = nil,
        subtitle: String? = nil,
        enhanced: Bool = false
    ) throws {
        if loadedFileName == fileName, isPlayingEnhanced == enhanced, player != nil { return }
        // Not `stop()`: that hands the audio session back to whatever was playing
        // before, and this is about to take it again. Switching recordings — or
        // flipping to the enhanced copy mid-listen — would otherwise let a paused
        // music app resume for the length of the swap.
        teardown(deactivatingSession: false)

        // Resolve through the shared store, which prefers the protected
        // `Documents/Recordings/` directory (where the recorder writes) and only
        // falls back to legacy `Documents/`. Building the path straight from
        // `documentsURL` misses every file in the protected subdirectory, so
        // playback failed with an OSStatus "operation could not be completed".
        let url = enhanced
            ? AudioFileStore.enhancedURL(fileName: fileName)
            : AudioFileStore.resolveURL(fileName: fileName)
        do {
            // `.spokenAudio` is what tells the system this is speech rather than
            // music: it ducks other audio correctly, and CarPlay and AirPods
            // apply their speech-tuned behaviour to it.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = playbackRate
            player.prepareToPlay()
            self.player = player
            self.duration = player.duration
            self.currentTime = 0
            self.loadedFileName = fileName
            self.isPlayingEnhanced = enhanced
            if let title { nowPlayingTitle = title }
            if let subtitle { nowPlayingSubtitle = subtitle }
            nowPlaying.activate(handlers: makeHandlers())
            publishNowPlaying()
        } catch {
            throw AppError.audioError(error.localizedDescription)
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        player.rate = playbackRate
        isPlaying = true
        startTimer()
        publishNowPlaying()
    }

    /// Set the playback speed, applying it live if a player is loaded.
    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
        publishNowPlaying()
    }

    /// Advance to the next speed in `rateOptions`, wrapping around. Used by the
    /// tappable speed pill in the player UI.
    func cycleRate() {
        let options = Self.rateOptions
        let index = options.firstIndex(of: playbackRate) ?? 0
        setRate(options[(index + 1) % options.count])
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        publishNowPlaying()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Seek to an absolute time within the loaded file.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
        publishNowPlaying()
    }

    /// Jump by `interval` seconds, clamped to the file. Negative goes back.
    func skip(by interval: TimeInterval) {
        guard player != nil else { return }
        seek(to: currentTime + interval)
    }

    /// Switch between the original and the enhanced copy without losing the
    /// listener's place. `load` goes through `stop()`, which resets position and
    /// duration, so both are captured first and restored after.
    func reload(enhanced: Bool) throws {
        guard let fileName = loadedFileName, isPlayingEnhanced != enhanced else { return }
        let position = currentTime
        let wasPlaying = isPlaying
        let title = nowPlayingTitle
        let subtitle = nowPlayingSubtitle
        try load(fileName: fileName, title: title, subtitle: subtitle, enhanced: enhanced)
        seek(to: position)
        if wasPlaying { play() }
    }

    func stop() {
        teardown(deactivatingSession: true)
    }

    private func teardown(deactivatingSession: Bool) {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        loadedFileName = nil
        isPlayingEnhanced = false
        nowPlayingTitle = nil
        nowPlayingSubtitle = nil
        wasPlayingBeforeInterruption = false
        stopTimer()
        nowPlaying.deactivate()
        guard deactivatingSession else { return }
        // Hand the route back so whatever was playing before (music, a podcast)
        // can resume. Leaving the session active holds it for the whole app
        // lifetime, since nothing else deactivates it.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - System transport

    private func makeHandlers() -> NowPlayingController.Handlers {
        NowPlayingController.Handlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            skip: { [weak self] interval in self?.skip(by: interval) },
            seek: { [weak self] position in self?.seek(to: position) }
        )
    }

    /// Push the state the system renders. Deliberately *not* called from the
    /// 0.1 s tick — Now Playing extrapolates the position from the rate, so the
    /// only moments that need publishing are the ones where that extrapolation
    /// would go wrong.
    private func publishNowPlaying() {
        nowPlaying.update(
            title: nowPlayingTitle,
            subtitle: nowPlayingSubtitle,
            duration: duration,
            position: currentTime,
            rate: isPlaying ? playbackRate : 0
        )
    }

    // MARK: - Session events

    private func registerNotifications() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            // The system has already stopped the player. Without this the app's
            // own state stays "playing" over silence.
            Task { @MainActor in
                self.wasPlayingBeforeInterruption = self.isPlaying
                if self.isPlaying { self.pause() }
            }
        case .ended:
            let shouldResume: Bool
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            } else {
                shouldResume = false
            }
            Task { @MainActor in
                if self.wasPlayingBeforeInterruption, shouldResume, self.player != nil {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.play()
                }
                self.wasPlayingBeforeInterruption = false
            }
        @unknown default:
            break
        }
    }

    @objc private nonisolated func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Unplugging headphones or losing a Bluetooth device must not dump a
        // meeting out of the speaker. This is the one route change that has to
        // pause; the rest (a new device arriving, a category change) do not.
        guard reason == .oldDeviceUnavailable else { return }
        Task { @MainActor in
            if self.isPlaying { self.pause() }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension AudioPlayerService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
            self.publishNowPlaying()
        }
    }
}
