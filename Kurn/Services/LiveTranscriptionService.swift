//
//  LiveTranscriptionService.swift
//  Kurn
//
//  Opt-in live transcription preview shown while recording. Wraps FluidAudio's
//  streaming ASR. The model is picked from the meeting language: English uses the
//  lightweight English-only Parakeet EOU; every other language (and auto-detect)
//  uses the multilingual streaming model so e.g. Portuguese is transcribed
//  correctly. This is preview-only: nothing here is ever persisted — the
//  authoritative transcript still comes from TranscriptionService after the
//  recording finishes.
//

import AVFoundation
import Foundation
import Observation

#if canImport(FluidAudio)
import FluidAudio

@MainActor
@Observable
final class LiveTranscriptionService {
    private(set) var partialText = ""
    private(set) var isActive = false
    private(set) var isLoading = false
    private(set) var isUnavailable = false

    private var engine: (any StreamingAsrManager)?
    /// Guards against unbounded `Task` growth: `append` drops a buffer instead
    /// of scheduling another `process` call while one is already in flight, so
    /// a slow/stalled engine can't pile up queued copies and Tasks.
    private let inFlight = InFlightGate()

    func start(language: MeetingLanguage) async {
        guard engine == nil, !isLoading else { return }
        isLoading = true
        isUnavailable = false
        partialText = ""
        defer { isLoading = false }
        let candidate: any StreamingAsrManager = language.usesEnglishOnlyStreamingModel
            ? StreamingModelVariant.parakeetEou160ms.createManager()
            : FluidAudioMultilingualStreamingManager()
        AppLog.transcription.atInfo.info("LiveTranscriptionService: loading streaming model for language=\(language.rawValue, privacy: .public)…")
        do {
            try await candidate.loadModels()
        } catch {
            AppLog.transcription.atError.error("LiveTranscriptionService: model load failed: \(error.localizedDescription, privacy: .public)")
            isUnavailable = true
            return
        }
        AppLog.transcription.atNotice.notice("LiveTranscriptionService: model loaded, activating live preview")
        // Wire the callback BEFORE flipping `isActive`, so the very first
        // chunk processed after activation can update the UI. (Previously the
        // callback was set after, racing with `processBufferedAudio` callers
        // and occasionally dropping the first partial emission.)
        await candidate.setPartialTranscriptCallback { [weak self] text in
            Task { @MainActor in self?.partialText = text }
        }
        engine = candidate
        isActive = true
    }

    /// Called from the audio render thread via `AudioRecorderService.onAudioBuffer`.
    /// Copies the buffer synchronously before dispatching, since the engine may
    /// recycle the original before an async task can read it. Drops the buffer
    /// if a previous one is still being processed instead of queuing more work.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard inFlight.tryAcquire() else { return }
        guard let copy = Self.copy(buffer) else {
            inFlight.release()
            return
        }
        // AVAudioPCMBuffer isn't Sendable; box it so the compiler doesn't have
        // to prove this freshly-allocated, never-aliased copy is safe to hand
        // off to the Task below.
        let box = UncheckedBufferBox(buffer: copy)
        Task { @MainActor [weak self] in
            await self?.process(box.buffer)
            self?.inFlight.release()
        }
    }

    func stop() async {
        guard let engine else {
            isActive = false
            isLoading = false
            partialText = ""
            return
        }
        do {
            _ = try await engine.finish()
        } catch {
            AppLog.transcription.atError.error("LiveTranscriptionService: finish failed: \(error.localizedDescription, privacy: .public)")
        }
        await engine.cleanup()
        self.engine = nil
        isActive = false
        isLoading = false
        partialText = ""
    }

    private func process(_ buffer: sending AVAudioPCMBuffer) async {
        guard let engine, isActive else { return }
        do {
            try await engine.appendAudio(buffer)
            try await engine.processBufferedAudio()
        } catch {
            // Best-effort preview; drop the buffer and keep listening.
            AppLog.transcription.atError.error("LiveTranscriptionService: append/process failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pure transform with no actor state — `nonisolated` so `append` (called
    /// from the audio render thread) can use it without hopping to the main actor.
    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

/// Carries a freshly-copied, never-aliased `AVAudioPCMBuffer` across the
/// `append` → `Task` handoff without requiring `AVAudioPCMBuffer` itself to
/// be `Sendable`.
private struct UncheckedBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Lock-protected single-slot in-flight flag, safe to call from the audio
/// render thread (`append`) and from the `@MainActor` completion (`process`).
private final class InFlightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isBusy = false

    func tryAcquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isBusy else { return false }
        isBusy = true
        return true
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        isBusy = false
    }
}

private extension MeetingLanguage {
    /// English uses the lighter English-only Parakeet EOU streaming model;
    /// everything else — including auto-detect, so a Portuguese speaker who
    /// leaves the meeting on "Auto" still gets sensible output — uses the
    /// multilingual streaming model via `FluidAudioMultilingualStreamingManager`.
    var usesEnglishOnlyStreamingModel: Bool {
        self == .english
    }
}

#else

/// Built without the FluidAudio package linked: the preview stays unavailable
/// until the package is added, but the recorder UI keeps working.
@MainActor
@Observable
final class LiveTranscriptionService {
    private(set) var partialText = ""
    private(set) var isActive = false
    private(set) var isLoading = false
    private(set) var isUnavailable = false

    func start(language: MeetingLanguage) async {
        isUnavailable = true
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {}

    func stop() async {
        isActive = false
        isLoading = false
        partialText = ""
    }
}

#endif
