//
//  SpeechLevelMeter.swift
//  Kurn
//
//  Streaming measurement of a recording's peak and speech level, and the makeup
//  gain those imply for the transcription cleanup chain.
//
//  `AudioPreprocessor` used to apply a fixed +8 dB of makeup gain on top of the
//  limiter's +3 dB pre-gain — +11 dB before limiting, regardless of how loud the
//  recording already was. On an already-healthy recording that drives the limiter
//  into near-constant gain reduction, and the distortion it leaves behind is
//  exactly the kind of artefact that costs a recogniser accuracy: recent work
//  finds enhancement front-ends *degrading* modern ASR precisely because they
//  introduce distortions the acoustic model never saw in training. Measuring the
//  recording first and deriving the gain lifts a quiet meeting without flattening
//  a loud one.
//
//  Measurement is O(1) in memory — frames are reduced to running sums as they
//  arrive — so a two-hour meeting costs the same as a two-second one.
//

import Accelerate
import Foundation

/// Peak and speech-level RMS of a recording, as linear magnitudes.
struct SpeechLevel: Equatable, Sendable {
    /// Largest absolute sample seen anywhere in the recording.
    var peak: Float
    /// RMS across only the frames judged to carry speech. Averaging *every* frame
    /// would measure a meeting that is mostly pauses as quiet, and then lift it
    /// until the talking parts clip.
    var speechRMS: Float

    static let silent = SpeechLevel(peak: 0, speechRMS: 0)
}

extension SpeechLevel {
    /// Where speech should land after the makeup gain. -20 dBFS leaves plenty of
    /// room for the peaks of an animated talker while being comfortably above the
    /// noise floor of any engine's front end.
    static let targetSpeechRMSDBFS: Float = -20
    /// The measured peak must not be pushed past this. The dynamics stage runs
    /// *before* the gain and pulls peaks down on its own, so treating the
    /// pre-compression peak as if it survived intact makes this bound
    /// conservative by design — it errs quiet, and the limiter catches the rest.
    static let peakCeilingDBFS: Float = -3
    /// Never attenuate (that is the limiter's job, and quietening a recording the
    /// user chose to make would be surprising) and never lift so far that the
    /// noise floor becomes the loudest thing in the room.
    static let gainRangeDB: ClosedRange<Float> = 0...18

    var peakDBFS: Float { Self.dBFS(peak) }
    var speechRMSDBFS: Float { Self.dBFS(speechRMS) }

    /// Makeup gain for this recording, in dB.
    var makeupGainDB: Float {
        Self.makeupGainDB(peakDBFS: peakDBFS, speechRMSDBFS: speechRMSDBFS)
    }

    /// Pure gain decision, split out from the measurement so it can be tested
    /// without any audio at all.
    static func makeupGainDB(peakDBFS: Float, speechRMSDBFS: Float) -> Float {
        // A silent or unreadable file measures as -infinity; leaving it alone is
        // the only safe answer, since any gain applied to silence just raises
        // whatever noise is there.
        guard peakDBFS.isFinite, speechRMSDBFS.isFinite else {
            return gainRangeDB.lowerBound
        }
        let wanted = targetSpeechRMSDBFS - speechRMSDBFS
        let headroom = peakCeilingDBFS - peakDBFS
        return min(max(min(wanted, headroom), gainRangeDB.lowerBound), gainRangeDB.upperBound)
    }

    /// dBFS of a linear magnitude, with a floor so digital silence returns
    /// `-infinity` rather than a NaN.
    static func dBFS(_ magnitude: Float) -> Float {
        magnitude > 1e-9 ? 20 * log10(magnitude) : -.infinity
    }
}

/// Accumulates `SpeechLevel` statistics from buffers as they are rendered.
///
/// Call `append` with each rendered buffer's samples and `finish` once, at the
/// end. The meter keeps a carry buffer across calls, so buffer boundaries do not
/// have to line up with frame boundaries.
struct SpeechLevelMeter {
    /// 20 ms at 16 kHz: long enough for a stable RMS, short enough that a frame
    /// is usually either speech or silence rather than a blend of the two.
    static let frameLength = 320

    /// Frames quieter than this are treated as silence and left out of the speech
    /// average. -60 dBFS is well below any real talker and well above the noise
    /// floor of a compressed recording.
    static let silenceFloorDBFS: Float = -60

    private static let silenceFloorPower = pow(10.0, Double(silenceFloorDBFS) / 10.0)

    private var peak: Float = 0
    private var activePowerSum: Double = 0
    private var activeFrames = 0
    private var totalPowerSum: Double = 0
    private var totalFrames = 0
    private var carry: [Float] = []

    init() {
        carry.reserveCapacity(Self.frameLength)
    }

    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }

        var bufferPeak: Float = 0
        vDSP_maxmgv(base, 1, &bufferPeak, vDSP_Length(samples.count))
        peak = max(peak, bufferPeak)

        var index = 0

        // Complete the frame left hanging by the previous buffer before starting
        // any new ones.
        if !carry.isEmpty {
            let take = min(Self.frameLength - carry.count, samples.count)
            carry.append(contentsOf: UnsafeBufferPointer(start: base, count: take))
            index = take
            if carry.count == Self.frameLength {
                let frame = carry
                carry.removeAll(keepingCapacity: true)
                frame.withUnsafeBufferPointer { accumulate($0.baseAddress!) }
            }
        }

        while index + Self.frameLength <= samples.count {
            accumulate(base.advanced(by: index))
            index += Self.frameLength
        }

        if index < samples.count {
            carry.append(
                contentsOf: UnsafeBufferPointer(
                    start: base.advanced(by: index),
                    count: samples.count - index
                )
            )
        }
    }

    /// Peak and speech level for everything appended so far.
    ///
    /// A trailing partial frame is deliberately dropped rather than zero-padded:
    /// it is at most 20 ms, and padding it would bias the level downward.
    func finish() -> SpeechLevel {
        if activeFrames > 0 {
            return SpeechLevel(
                peak: peak,
                speechRMS: Float((activePowerSum / Double(activeFrames)).squareRoot())
            )
        }
        // Nothing cleared the silence floor — a very quiet recording. Fall back to
        // the overall average so the gain decision still has something real to
        // work with instead of treating the file as digital silence.
        guard totalFrames > 0 else { return .silent }
        return SpeechLevel(
            peak: peak,
            speechRMS: Float((totalPowerSum / Double(totalFrames)).squareRoot())
        )
    }

    private mutating func accumulate(_ frame: UnsafePointer<Float>) {
        var sumSquares: Float = 0
        vDSP_svesq(frame, 1, &sumSquares, vDSP_Length(Self.frameLength))
        let power = Double(sumSquares) / Double(Self.frameLength)

        totalPowerSum += power
        totalFrames += 1

        if power >= Self.silenceFloorPower {
            activePowerSum += power
            activeFrames += 1
        }
    }
}
