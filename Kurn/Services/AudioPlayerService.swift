//
//  AudioPlayerService.swift
//  Kurn
//
//  AVAudioPlayer wrapper for transcript-synced playback. Exposes observable
//  position/duration and supports seeking to a segment timestamp.
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

    private var player: AVAudioPlayer?
    private var timer: Timer?

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
    func load(fileName: String, enhanced: Bool = false) throws {
        if loadedFileName == fileName, isPlayingEnhanced == enhanced, player != nil { return }
        stop()

        // Resolve through the shared store, which prefers the protected
        // `Documents/Recordings/` directory (where the recorder writes) and only
        // falls back to legacy `Documents/`. Building the path straight from
        // `documentsURL` misses every file in the protected subdirectory, so
        // playback failed with an OSStatus "operation could not be completed".
        let url = enhanced
            ? AudioFileStore.enhancedURL(fileName: fileName)
            : AudioFileStore.resolveURL(fileName: fileName)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
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
    }

    /// Set the playback speed, applying it live if a player is loaded.
    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
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
    }

    /// Switch between the original and the enhanced copy without losing the
    /// listener's place. `load` goes through `stop()`, which resets position and
    /// duration, so both are captured first and restored after.
    func reload(enhanced: Bool) throws {
        guard let fileName = loadedFileName, isPlayingEnhanced != enhanced else { return }
        let position = currentTime
        let wasPlaying = isPlaying
        try load(fileName: fileName, enhanced: enhanced)
        seek(to: position)
        if wasPlaying { play() }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        loadedFileName = nil
        isPlayingEnhanced = false
        stopTimer()
    }

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
        }
    }
}
