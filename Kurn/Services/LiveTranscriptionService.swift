//
//  LiveTranscriptionService.swift
//  Kurn
//
//  Opt-in live transcription preview shown while recording. Wraps FluidAudio's
//  streaming ASR (Parakeet EOU). This is preview-only: nothing here is ever
//  persisted — the authoritative transcript still comes from
//  TranscriptionService after the recording finishes.
//

import AVFoundation
import FluidAudio
import Foundation
import Observation

@MainActor
@Observable
final class LiveTranscriptionService {
    private(set) var partialText = ""
    private(set) var isActive = false
    private(set) var isUnavailable = false

    private var engine: (any StreamingAsrManager)?

    func start() async {
        guard engine == nil else { return }
        let candidate = StreamingModelVariant.parakeetEou160ms.createManager()
        do {
            try await candidate.loadModels()
        } catch {
            isUnavailable = true
            return
        }
        await candidate.setPartialTranscriptCallback { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }
        engine = candidate
        isActive = true
        isUnavailable = false
        partialText = ""
    }

    /// Called from the audio render thread via `AudioRecorderService.onAudioBuffer`.
    /// Copies the buffer synchronously before dispatching, since the engine may
    /// recycle the original before an async task can read it.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        Task { @MainActor [weak self] in
            await self?.process(copy)
        }
    }

    func stop() async {
        guard let engine else { return }
        _ = try? await engine.finish()
        await engine.cleanup()
        self.engine = nil
        isActive = false
        partialText = ""
    }

    private func process(_ buffer: AVAudioPCMBuffer) async {
        guard let engine, isActive else { return }
        do {
            try await engine.appendAudio(buffer)
            try await engine.processBufferedAudio()
        } catch {
            // Best-effort preview; drop the buffer and keep listening.
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return copy }
        let channelCount = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<channelCount {
                dst[channel].update(from: src[channel], count: frames)
            }
        }
        return copy
    }
}
