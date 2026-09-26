//
//  CloudSpeechEngine.swift
//  Kurn
//
//  Plays cloud text-to-speech one chunk at a time, fetching the next chunk
//  while the current one plays so there is no gap between paragraphs beyond
//  the first request. Audio is decoded from memory (`AVAudioPlayer(data:)`)
//  and dropped once played: it is derived from meeting content, and nothing
//  here earns a file on disk.
//

import AVFoundation
import Foundation
import KurnCore

@MainActor
final class CloudSpeechEngine: NSObject, ReadAloudEngine {
    var onChunkStarted: ((Int) -> Void)?
    var onFinished: (() -> Void)?
    var onFailed: ((AppError) -> Void)?

    private let provider: any SpeechSynthesisProvider
    private let languageCode: String?
    private let rate: Float

    private var chunks: [String] = []
    private var currentIndex = 0
    private var player: AVAudioPlayer?
    private var fetches: [Int: Task<Data, Error>] = [:]
    private var isPaused = false
    /// Bumped on every start/stop so a fetch that completes after the user
    /// skipped or stopped cannot start playing stale audio.
    private var generation = 0

    init(provider: any SpeechSynthesisProvider, languageCode: String?, rate: Float) {
        self.provider = provider
        self.languageCode = languageCode
        self.rate = rate
        super.init()
    }

    func start(_ chunks: [String], at index: Int) {
        stop()
        self.chunks = chunks
        play(index)
    }

    func pause() {
        isPaused = true
        player?.pause()
    }

    func resume() {
        isPaused = false
        player?.play()
    }

    func stop() {
        generation += 1
        fetches.values.forEach { $0.cancel() }
        fetches.removeAll()
        player?.stop()
        player = nil
        isPaused = false
    }

    private func fetch(_ index: Int) -> Task<Data, Error> {
        if let existing = fetches[index] { return existing }
        let provider = self.provider
        let text = chunks[index]
        let languageCode = self.languageCode
        let task = Task { try await provider.synthesize(text, languageCode: languageCode) }
        fetches[index] = task
        return task
    }

    private func play(_ index: Int) {
        guard chunks.indices.contains(index) else {
            onFinished?()
            return
        }
        currentIndex = index
        let token = generation
        let pending = fetch(index)
        Task { [weak self] in
            let result: Result<Data, Error>
            do {
                result = .success(try await pending.value)
            } catch {
                result = .failure(error)
            }
            self?.handle(result, for: index, token: token)
        }
    }

    private func handle(_ result: Result<Data, Error>, for index: Int, token: Int) {
        guard token == generation else { return }
        fetches[index] = nil
        do {
            let player = try AVAudioPlayer(data: try result.get())
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            self.player = player
            if !isPaused { player.play() }
            if chunks.indices.contains(index + 1) { _ = fetch(index + 1) }
            onChunkStarted?(index)
        } catch is CancellationError {
            return
        } catch let error as AppError {
            AppLog.generation.atError.error("CloudSpeechEngine: chunk \(index, privacy: .public) failed code=\(error.logCode, privacy: .public)")
            onFailed?(error)
        } catch {
            AppLog.generation.atError.error("CloudSpeechEngine: chunk \(index, privacy: .public) failed code=\(error.publicLogCode, privacy: .public)")
            onFailed?(.speechSynthesisFailed(error.localizedDescription))
        }
    }

    private func playerDidFinish(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        play(currentIndex + 1)
    }
}

extension CloudSpeechEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerDidFinish(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == id else { return }
            self.onFailed?(.speechSynthesisFailed(
                NSLocalizedString("read_aloud.error.no_audio", comment: "Provider returned no audio")
            ))
        }
    }
}
