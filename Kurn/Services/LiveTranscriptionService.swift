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
import KurnCore
import Observation

#if canImport(FluidAudio)
import FluidAudio

@MainActor
@Observable
final class LiveTranscriptionService {
    typealias EngineFactory = @MainActor @Sendable (MeetingLanguage, FluidAudioLiveModel) async throws -> any StreamingAsrManager

    private(set) var partialText = ""
    private(set) var isActive = false
    private(set) var isLoading = false
    private(set) var isUnavailable = false

    private var engine: (any StreamingAsrManager)?
    private let isUnifiedInstalled: () -> Bool
    private let engineFactory: EngineFactory
    @ObservationIgnored private var pumpTask: Task<Void, Never>?

    init(
        isUnifiedInstalled: @escaping () -> Bool = { FluidAudioASRModelRuntime.isUnifiedStreamingInstalled },
        engineFactory: @escaping EngineFactory = LiveTranscriptionService.makeEngine
    ) {
        self.isUnifiedInstalled = isUnifiedInstalled
        self.engineFactory = engineFactory
    }

    deinit {
        audioQueue.invalidate()
        pumpTask?.cancel()
    }

    var droppedAudioBufferCount: Int { audioQueue.snapshot.droppedCount }
    var queuedAudioDuration: TimeInterval { audioQueue.snapshot.cost }

    /// Bounds queued audio while a single session pump awaits the model, so
    /// incoming buffers remain available when processing resumes. Only backlog
    /// beyond eight seconds drops oldest buffers; append never creates Tasks.
    private nonisolated let audioQueue = LiveAudioQueue(maximumCost: 8)

    func start(
        language: MeetingLanguage,
        modelsConsented: Bool = false,
        policy: LargeTransferPolicy = .wifiOnly,
        model: FluidAudioLiveModel = .default
    ) async {
        guard engine == nil, !isLoading else { return }
        guard modelsConsented else {
            isUnavailable = true
            return
        }
        if model == .nemotronUnified && (!model.supports(language) || !isUnifiedInstalled()) {
            isUnavailable = true
            return
        }
        let session = audioQueue.begin()
        isLoading = true
        isUnavailable = false
        partialText = ""
        defer { if audioQueue.isCurrent(session) { isLoading = false } }
        let candidate: any StreamingAsrManager
        AppLog.transcription.atInfo.info("LiveTranscriptionService: loading streaming model for language=\(language.rawValue, privacy: .public)…")
        do {
            candidate = try await engineFactory(language, model)
        } catch {
            guard audioQueue.isCurrent(session) else { return }
            let code = (error as? AppError)?.logCode ?? "unexpected"
            AppLog.transcription.atError.error("LiveTranscriptionService: model load failed code=\(code, privacy: .public)")
            isUnavailable = true
            isLoading = false
            audioQueue.invalidate(session)
            return
        }
        guard audioQueue.isCurrent(session) else {
            await candidate.cleanup()
            return
        }
        AppLog.transcription.atNotice.notice("LiveTranscriptionService: model loaded, activating live preview")
        // Wire the callback BEFORE flipping `isActive`, so the very first
        // chunk processed after activation can update the UI. (Previously the
        // callback was set after, racing with `processBufferedAudio` callers
        // and occasionally dropping the first partial emission.)
        await candidate.setPartialTranscriptCallback { [weak self] text in
            Task { @MainActor in
                guard let self, self.audioQueue.isCurrent(session), self.isActive else { return }
                self.partialText = text
            }
        }
        guard audioQueue.activate(session) else {
            await candidate.cleanup()
            return
        }
        engine = candidate
        isActive = true
        startPump(engine: candidate, session: session)
    }

    static func makeEngine(language: MeetingLanguage, model: FluidAudioLiveModel) async throws -> any StreamingAsrManager {
        if model == .nemotronUnified {
            let unified = FluidAudioUnifiedStreamingManager(language: language)
            try await unified.loadModels()
            return unified
        }
        return try await FluidAudioAutomaticStreamingRuntime.load(language: language)
    }

    /// Called from the audio render thread via `AudioRecorderService.onAudioBuffer`.
    /// Copies the buffer synchronously before dispatching, since the engine may
    /// recycle the original before an async task can read it. Queues audio while
    /// the session pump awaits the model, discarding only oldest overflow.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let session = audioQueue.receivingToken else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard duration.isFinite, duration > 0, let copy = Self.copy(buffer) else { return }
        // AVAudioPCMBuffer isn't Sendable; box it so the compiler doesn't have
        // to prove this freshly-allocated, never-aliased copy is safe to hand
        // off to the Task below.
        let box = UncheckedBufferBox(buffer: copy)
        audioQueue.enqueue(box, cost: duration, for: session)
    }

    private func startPump(engine: any StreamingAsrManager, session: LiveAudioQueue.Token) {
        let queue = audioQueue
        pumpTask = Task { @MainActor [weak self] in
            while let box = await queue.next(for: session) {
                guard queue.isCurrent(session), !Task.isCancelled else { return }
                await self?.process(box.buffer, engine: engine, session: session)
            }
        }
    }

    func stop() async {
        audioQueue.invalidate()
        let engine = self.engine
        self.engine = nil
        let pump = pumpTask
        pumpTask = nil
        isActive = false
        isLoading = false
        partialText = ""
        pump?.cancel()
        await pump?.value
        guard let engine else { return }
        do {
            _ = try await engine.finish()
        } catch {
            AppLog.transcription.atError.error("LiveTranscriptionService: finish failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
        }
        await engine.cleanup()
    }

    private func process(
        _ buffer: sending AVAudioPCMBuffer,
        engine: any StreamingAsrManager,
        session: LiveAudioQueue.Token
    ) async {
        guard audioQueue.isCurrent(session), isActive else { return }
        do {
            try await engine.appendAudio(buffer)
            guard audioQueue.isCurrent(session) else { return }
            try await engine.processBufferedAudio()
        } catch {
            // Best-effort preview; drop the buffer and keep listening.
            guard audioQueue.isCurrent(session) else { return }
            AppLog.transcription.atError.error("LiveTranscriptionService: append/process failed code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)")
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

/// Bounded session queue, safe to feed from the audio render thread
/// (`append`) and drain from the `@MainActor` pump across model awaits.
private typealias LiveAudioQueue = BoundedSessionQueue<UncheckedBufferBox>

extension MeetingLanguage {
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

    var droppedAudioBufferCount: Int { 0 }
    var queuedAudioDuration: TimeInterval { 0 }

    func start(
        language: MeetingLanguage,
        modelsConsented: Bool = false,
        policy: LargeTransferPolicy = .wifiOnly,
        model: FluidAudioLiveModel = .default
    ) async {
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
