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

    /// Speeds the user can cycle through, mirroring WhatsApp's voice-note control.
    static let rateOptions: [Float] = [1.0, 1.5, 2.0, 0.5]

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Load a recording. Reuses the existing player if the same file is loaded.
    func load(fileName: String) throws {
        if loadedFileName == fileName, player != nil { return }
        stop()

        let url = AudioFileStore.documentsURL.appendingPathComponent(fileName)
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

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        loadedFileName = nil
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
