//
//  RecordingSink.swift
//  Kurn
//
//  The write end of `AudioRecorderService`: owns the output file, the resampler
//  feeding it, and the latest input level. Split out of the recorder because the
//  two have different concurrency stories — the recorder is `@MainActor`, this is
//  a lock-guarded box the audio render thread calls directly.
//

import AVFoundation
import Foundation

enum AudioSinkFailure: String, Equatable, Error, Sendable {
    case conversion = "conversion_failed"
    case write = "write_failed"
    case finalDrain = "final_drain_failed"
}

struct AudioSinkSnapshot: Equatable, Sendable {
    var firstFailure: AudioSinkFailure?
    var attemptedInputFrames: Int64
    var writtenOutputFrames: Int64
    var lastSuccessfulWriteAt: Date?

    init(
        firstFailure: AudioSinkFailure? = nil,
        attemptedInputFrames: Int64 = 0,
        writtenOutputFrames: Int64 = 0,
        lastSuccessfulWriteAt: Date? = nil
    ) {
        self.firstFailure = firstFailure
        self.attemptedInputFrames = attemptedInputFrames
        self.writtenOutputFrames = writtenOutputFrames
        self.lastSuccessfulWriteAt = lastSuccessfulWriteAt
    }
}

protocol AudioFileWriting: AnyObject {
    func write(from buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: AudioFileWriting {}

/// The surface `AudioRecorderService` needs from its sink, carved out so a
/// fake can stand in for `RecordingSink` in tests — the real-time render
/// thread's write path had no injection point at all before this. The sink
/// exposes only a bounded snapshot; `AudioRecorderService` reads it on the
/// main-actor metering tick instead of touching UI from the render thread.
protocol AudioSinkWriting: Sendable {
    func open(
        _ file: any AudioFileWriting,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        onBuffer: ((AVAudioPCMBuffer) -> Void)?
    )
    func replaceConverter(_ converter: AVAudioConverter)
    var currentTargetFormat: AVAudioFormat? { get }
    func setPaused(_ value: Bool)
    func close()
    var currentLevel: Float { get }
    var snapshot: AudioSinkSnapshot { get }
    @discardableResult func write(_ buffer: AVAudioPCMBuffer) -> Bool
}

/// Thread-safe owner of the recording file and the latest input level. The audio
/// tap runs on a real-time render thread; routing all file/level access through
/// this lock-guarded box keeps it off the main actor and free of data races.
///
/// It also owns the resample step. `AVAudioFile.write(from:)` requires buffers in
/// the file's `processingFormat`, and the file is deliberately opened at a fixed
/// speech format rather than the tap's (see
/// `AudioRecorderService.storageSampleRate`), so every buffer passes through
/// `converter` on its way to disk.
final class RecordingSink: AudioSinkWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var file: (any AudioFileWriting)?
    private var paused = true
    private var level: Float = 0
    private var sinkSnapshot = AudioSinkSnapshot()
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func open(
        _ file: any AudioFileWriting,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        onBuffer: ((AVAudioPCMBuffer) -> Void)?
    ) {
        lock.lock(); defer { lock.unlock() }
        self.file = file
        self.converter = converter
        self.targetFormat = targetFormat
        self.onBuffer = onBuffer
        paused = false
        level = 0
        sinkSnapshot = AudioSinkSnapshot()
    }

    /// Swap in a converter for a new input format, keeping the open file. Used by
    /// the engine-stall recovery when the route changed mid-recording: the stored
    /// format is fixed, so only the front of the chain has to be rebuilt.
    func replaceConverter(_ converter: AVAudioConverter) {
        lock.lock(); defer { lock.unlock() }
        self.converter = converter
    }

    /// The format the sink converts to, for callers rebuilding a converter.
    var currentTargetFormat: AVAudioFormat? {
        lock.lock(); defer { lock.unlock() }
        return targetFormat
    }

    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
        if value { level = 0 }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        // Drain whatever the resampler is still holding (well under a
        // millisecond) so the tail of the recording isn't clipped.
        if let file, let converter, let targetFormat {
            switch Self.drain(converter: converter, to: targetFormat) {
            case .success(let tail):
                if let tail, tail.frameLength > 0 {
                    do {
                        try file.write(from: tail)
                        sinkSnapshot.writtenOutputFrames += Int64(tail.frameLength)
                        sinkSnapshot.lastSuccessfulWriteAt = now()
                    } catch {
                        latch(.finalDrain)
                    }
                }
            case .failure:
                latch(.finalDrain)
            }
        }
        file = nil
        converter = nil
        targetFormat = nil
        onBuffer = nil
        paused = true
        level = 0
    }

    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    var snapshot: AudioSinkSnapshot {
        lock.lock(); defer { lock.unlock() }
        return sinkSnapshot
    }

    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        guard !paused, let file, let converter, let targetFormat else { lock.unlock(); return false }
        sinkSnapshot.attemptedInputFrames += Int64(buffer.frameLength)
        guard sinkSnapshot.firstFailure == nil else { lock.unlock(); return false }

        let converted: AVAudioPCMBuffer
        switch Self.convert(buffer, using: converter, to: targetFormat) {
        case .success(let output):
            guard let output else { lock.unlock(); return true }
            converted = output
        case .failure:
            latch(.conversion)
            lock.unlock()
            return false
        }

        let succeeded: Bool
        do {
            try file.write(from: converted)
            sinkSnapshot.writtenOutputFrames += Int64(converted.frameLength)
            sinkSnapshot.lastSuccessfulWriteAt = now()
            succeeded = true
        } catch {
            latch(.write)
            succeeded = false
        }
        level = succeeded ? Self.level(of: converted) : 0
        let callback = succeeded ? onBuffer : nil
        lock.unlock()
        // Hand the live-transcription preview the converted buffer: 24kHz mono is
        // closer to the 16kHz the streaming engines want than the mic's native
        // rate was, and it is a smaller buffer to copy on the render thread.
        callback?(converted)
        return succeeded
    }

    private func latch(_ failure: AudioSinkFailure) {
        if sinkSnapshot.firstFailure == nil {
            sinkSnapshot.firstFailure = failure
        }
    }

    /// Resample one tap buffer. Sample rate conversion is not 1:1, so this needs
    /// the input-block form of `convert` — the buffer-to-buffer overload only
    /// handles conversions that keep the frame count.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> Result<AVAudioPCMBuffer?, AudioSinkFailure> {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else {
            return .failure(.conversion)
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        // A little slack above the theoretical frame count: the resampler can
        // emit frames it buffered from a previous call along with this one.
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return .failure(.conversion)
        }

        let input = ConverterInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let next = input.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            // `inputRanDry` is the steady state here: we hand over exactly one
            // buffer per call, and the resampler may hold a few frames back to
            // combine with the next one.
            return .success(output.frameLength > 0 ? output : nil)
        case .error:
            return .failure(.conversion)
        @unknown default:
            return .failure(.conversion)
        }
    }

    /// Flush the resampler's remaining frames at end of stream.
    private static func drain(
        converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> Result<AVAudioPCMBuffer?, AudioSinkFailure> {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            return .failure(.finalDrain)
        }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        switch status {
        case .haveData, .endOfStream:
            return .success(output.frameLength > 0 ? output : nil)
        case .inputRanDry:
            return .success(nil)
        case .error:
            return .failure(.finalDrain)
        @unknown default:
            return .failure(.finalDrain)
        }
    }

    /// Hands one buffer to `AVAudioConverter`'s input block, then reports the
    /// input as dry.
    ///
    /// `AVAudioConverterInputBlock` is `@Sendable`, so a captured `var` flag and
    /// a captured `AVAudioPCMBuffer` both trip Swift 6's concurrency checks even
    /// though `convert(to:error:withInputFrom:)` invokes the block synchronously,
    /// on this thread, before it returns. Boxing the state keeps the checker
    /// satisfied without pretending the buffer itself is `Sendable`.
    private final class ConverterInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    /// Map a buffer's RMS energy to a perceptual 0...1 with a −50 dBFS floor,
    /// matching the metering curve the UI was tuned against.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        let samples = channels[0]
        for i in 0..<frames {
            let sample = samples[i]
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let floor: Float = -50
        let clamped = max(floor, db)
        return (clamped - floor) / (-floor)
    }
}
