//
//  FluidAudioMultilingualStreamingManager.swift
//  Kurn
//
//  Adapts FluidAudio's `StreamingNemotronMultilingualAsrManager` to the
//  `StreamingAsrManager` protocol that `LiveTranscriptionService` dispatches
//  through. The multilingual streaming engine predates that protocol and
//  ships its own bespoke API (`loadModels(from: URL)` instead of a
//  parameterless `loadModels()`, `setPartialCallback` instead of
//  `setPartialTranscriptCallback`, no `displayName`), so it isn't one of the
//  cases `StreamingModelVariant.createManager()` can produce — this wraps it
//  instead of trying to make FluidAudio conform it directly.
//

import AVFoundation
import Foundation

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioMultilingualStreamingManager: StreamingAsrManager {
    private let manager = StreamingNemotronMultilingualAsrManager()
    private let audioConverter = AudioConverter()
    private let chunkMs: Int

    /// Resampled audio waiting to be drained by `processBufferedAudio()`.
    /// Buffered locally (instead of inside `manager`) so `appendAudio`,
    /// which the protocol declares non-`async`, never has to cross into the
    /// wrapped manager's own actor isolation.
    private var pendingSamples: [Float] = []

    /// Mirrors the wrapped manager's latest partial transcript so
    /// `getPartialTranscript()` — also non-`async` per the protocol — can
    /// return synchronously instead of awaiting a cross-actor call.
    private var cachedPartialText = ""
    private var externalCallback: (@Sendable (String) -> Void)?

    init(chunkMs: Int = 2240) {
        self.chunkMs = chunkMs
    }

    var displayName: String { "Nemotron Multilingual 0.6B (\(chunkMs)ms)" }

    func loadModels() async throws {
        let directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto", chunkMs: chunkMs)
        try await manager.loadModels(from: directory)
        await manager.setPartialCallback { [weak self] text in
            Task { await self?.handlePartial(text) }
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) throws {
        try StreamingAsrUtils.appendAudio(buffer, using: audioConverter, to: &pendingSamples)
    }

    func processBufferedAudio() async throws {
        guard !pendingSamples.isEmpty else { return }
        let samples = pendingSamples
        pendingSamples.removeAll()
        _ = try await manager.process(samples: samples)
    }

    func finish() async throws -> String {
        try await manager.finish()
    }

    func reset() async throws {
        await manager.reset()
        pendingSamples.removeAll()
        cachedPartialText = ""
    }

    func cleanup() async {
        await manager.cleanup()
        pendingSamples.removeAll()
        cachedPartialText = ""
        externalCallback = nil
    }

    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {
        externalCallback = callback
    }

    func getPartialTranscript() -> String {
        cachedPartialText
    }

    private func handlePartial(_ text: String) {
        cachedPartialText = text
        externalCallback?(text)
    }
}

#endif
