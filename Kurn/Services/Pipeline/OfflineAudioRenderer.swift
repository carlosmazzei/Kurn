//
//  OfflineAudioRenderer.swift
//  Kurn
//
//  The one offline decode/resample loop the app uses to read its own recordings.
//
//  Every consumer of a stored `.m4a` goes through `AVAudioEngine` in
//  `.offline` manual-rendering mode, driven by an `AVAudioPlayerNode`, rather
//  than the more obvious `AVAudioFile.read` or `AVAudioConverter`: on device
//  both of those decode paths fail with a generic "erro 0" on the app's
//  compressed AAC files (see `VADAudioLoader`, which hit exactly that). This
//  type owns the loop so `AudioPreprocessor`, `DiarizationPreprocessor` and
//  `RecordingCompactor` share one copy of it instead of three, and differ only
//  in the DSP chain they insert and what they do with each rendered buffer.
//
//  Rendering is streamed buffer by buffer, so memory stays flat regardless of
//  how long the meeting is — the caller decides whether to accumulate.
//
//  `VADAudioLoader.monoSamples` keeps its own copy of the loop on purpose: it is
//  synchronous, and the callers that need it (`FluidAudioVAD`, `SpeakerDiarizer`,
//  `WhisperCppTranscriber`) would all have to become `async` to adopt this, which
//  buys nothing. Keep the two in sync if the decode path ever has to change.
//

import AVFoundation
import Foundation
import os

struct OfflineAudioRenderer {
    /// Inserts the caller's DSP nodes between `player` and the engine's main
    /// mixer, connecting them in the *input* file's format. The main mixer
    /// handles the resample/downmix to `outputFormat` on the way out, which is
    /// why chains connect at the source format rather than the target.
    typealias ChainBuilder = (
        _ engine: AVAudioEngine,
        _ player: AVAudioPlayerNode,
        _ inputFormat: AVAudioFormat
    ) -> Void

    /// Format buffers are handed to `onBuffer` in — and, for callers writing a
    /// file, the format that file should be opened at.
    let outputFormat: AVAudioFormat
    /// Frames per `renderOffline` call. 4096 keeps the render buffer tiny while
    /// still amortizing the per-call overhead.
    var maxFrames: AVAudioFrameCount = 4096
    /// Builds the DSP chain. The default is a straight player → mixer wire, i.e.
    /// decode and resample with no processing.
    var buildChain: ChainBuilder = { engine, player, inputFormat in
        engine.connect(player, to: engine.mainMixerNode, format: inputFormat)
    }
    /// Called right after `engine.start()`. Audio units are only initialized by
    /// `start()`, so parameter setting has to happen here rather than in
    /// `buildChain`.
    var afterStart: ((AVAudioEngine) -> Void)?
    /// Thrown when the input file or the engine can't be set up. Callers pass
    /// their own so the user-facing message matches the feature that failed.
    var failure: AppError
    /// Prefix for this renderer's log lines, e.g. "preprocess".
    var logLabel: String

    /// Decode `url` through the chain, handing every rendered buffer to
    /// `onBuffer`. Returns the number of frames actually rendered, which can be
    /// short of the estimate when the source's sample table runs out early.
    ///
    /// The buffer passed to `onBuffer` is reused between iterations — copy out of
    /// it rather than retaining it.
    ///
    /// Runs in the *caller's* isolation domain (`isolation: … = #isolation`), not
    /// on the generic executor. That is deliberate: `onBuffer` captures
    /// non-`Sendable` state — an `AVAudioFile` for the callers that write a file,
    /// a mutable array for the one that accumulates samples — which Swift 6 will
    /// not let cross isolation domains. Keeping the loop where the caller already
    /// is also preserves the pre-extraction behaviour exactly: an `actor` caller
    /// renders on its own executor, and `RecordingCompactor`, being nonisolated,
    /// renders off the main actor.
    @discardableResult
    func render(
        url: URL,
        isolation: isolated (any Actor)? = #isolation,
        onBuffer: (AVAudioPCMBuffer) throws -> Void
    ) async throws -> AVAudioFramePosition {
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        let totalInputFrames = inputFile.length
        AppLog.transcription.atDebug.debug("\(self.logLabel, privacy: .public): input sampleRate=\(inputFormat.sampleRate, privacy: .public) channels=\(inputFormat.channelCount, privacy: .public) frames=\(totalInputFrames, privacy: .public)")
        guard totalInputFrames > 0, inputFormat.sampleRate > 0 else {
            AppLog.transcription.atError.error("\(self.logLabel, privacy: .public): invalid input (no frames or zero sample rate)")
            throw failure
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        buildChain(engine, player, inputFormat)

        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: maxFrames)
        try engine.start()
        afterStart?(engine)
        Self.scheduleForOfflineRender(inputFile, on: player)
        player.play()

        defer {
            player.stop()
            engine.stop()
        }

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: maxFrames
        ) else {
            throw failure
        }

        // Cap on output frames given the resample ratio, so a source that never
        // reports exhaustion can't spin forever.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let expectedOutFrames = AVAudioFramePosition(Double(totalInputFrames) * ratio)

        var resourceCheckCounter = 0
        var lastLoggedProgress = 0.0
        renderLoop: while engine.manualRenderingSampleTime < expectedOutFrames {
            if resourceCheckCounter.isMultiple(of: 128) {
                try await ResourceGuard.requireTranscriptionHeadroom()
            }
            resourceCheckCounter += 1
            let remaining = expectedOutFrames - engine.manualRenderingSampleTime
            let framesToRender = AVAudioFrameCount(min(Int64(maxFrames), remaining))
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(framesToRender, to: renderBuffer)
            } catch {
                try ResourceGuard.rethrowIfResourceFailure(error)
                throw error
            }
            switch status {
            case .success:
                do {
                    try onBuffer(renderBuffer)
                } catch {
                    try ResourceGuard.rethrowIfResourceFailure(error)
                    throw error
                }
            case .insufficientDataFromInputNode:
                // Source exhausted — we're done.
                AppLog.transcription.atDebug.debug("\(self.logLabel, privacy: .public): input exhausted at \(engine.manualRenderingSampleTime, privacy: .public) frames")
                break renderLoop
            case .cannotDoInCurrentContext, .error:
                AppLog.transcription.atError.error("\(self.logLabel, privacy: .public): render stopped early (status=\(status.rawValue, privacy: .public)) at \(engine.manualRenderingSampleTime, privacy: .public) frames")
                break renderLoop
            @unknown default:
                break renderLoop
            }
            // Log progress at ~25% increments so a slow/stuck render is visible.
            let progress = Double(engine.manualRenderingSampleTime) / Double(max(1, expectedOutFrames))
            if progress - lastLoggedProgress >= 0.25 {
                lastLoggedProgress = progress
                AppLog.transcription.atDebug.debug("\(self.logLabel, privacy: .public): render progress \(Int(progress * 100), privacy: .public)%")
            }
        }

        return engine.manualRenderingSampleTime
    }

    /// Mono Float32 output format at `sampleRate`, the shape every machine
    /// consumer of the audio wants.
    static func monoFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    }

    /// Schedule a file for offline rendering without awaiting.
    ///
    /// The `async` overload of `scheduleFile` only returns once the file has
    /// finished *playing*, but in offline manual-rendering mode the audio is
    /// consumed solely by the `renderOffline` loop — awaiting it deadlocks (the
    /// loop is never reached, so playback never completes). We deliberately use
    /// the completion-handler overload instead. Keeping this in a synchronous
    /// helper also avoids the compiler's "consider using the asynchronous
    /// alternative" warning that fires when it is called from an `async` context.
    private static func scheduleForOfflineRender(_ file: AVAudioFile, on player: AVAudioPlayerNode) {
        player.scheduleFile(file, at: nil, completionHandler: nil)
    }
}
