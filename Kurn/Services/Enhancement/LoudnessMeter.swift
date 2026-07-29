//
//  LoudnessMeter.swift
//  Kurn
//
//  Integrated loudness to ITU-R BS.1770-4, so every enhanced copy is rendered to
//  the same perceived level. Without it, one meeting plays back quiet and the next
//  is startling, and the user rides the volume slider between recordings.
//
//  Peak or RMS normalization would be cheaper but would not do the job: neither
//  tracks how loud speech actually *sounds*. BS.1770 applies a K-weighting curve
//  (a head-shadow shelf plus a low-cut) and then throws away the quiet parts
//  through two gates, so pauses between sentences don't drag the measurement down
//  and a single door slam doesn't drag it up.
//
//  **Everything here assumes 48 kHz.** The filter coefficients in the standard are
//  specified at that rate, and using them at another one silently measures the
//  wrong thing — they would have to be re-derived from the analog prototype. The
//  caller renders its measurement pass at 48 kHz for exactly this reason; it costs
//  nothing, since the pass is a resample either way.
//
//  Memory is one `Double` per 100 ms of audio (~288 KB for an hour), because the
//  gating decisions can only be made once the whole signal has been seen.
//

import Accelerate
import Foundation

struct LoudnessMeter {

    /// The rate the coefficients below are valid at. Not a preference.
    static let requiredSampleRate: Double = 48_000

    /// BS.1770 measures over 400 ms blocks overlapping by 75%, i.e. a new block
    /// every 100 ms. Blocks are accumulated as four consecutive 100 ms steps so
    /// each sample is squared once rather than four times.
    static let blockSeconds = 0.4
    static let stepSeconds = 0.1
    private static let stepsPerBlock = 4

    /// Blocks quieter than this are silence, not quiet speech, and are excluded
    /// outright.
    static let absoluteGateLUFS = -70.0
    /// Blocks more than this far below the ungated average are excluded too, which
    /// is what keeps room tone and pauses from pulling the result down.
    static let relativeGateLU = -10.0
    /// The calibration constant from the standard.
    private static let offset = -0.691

    private var preFilter = Biquad.bs1770HighShelf
    private var rlbFilter = Biquad.bs1770HighPass
    private let stepSamples: Int
    private var stepSum: Double = 0
    private var stepCount = 0
    private var stepSums: [Double] = []

    init() {
        stepSamples = Int(Self.requiredSampleRate * Self.stepSeconds)
    }

    /// Feed mono samples **at 48 kHz**.
    mutating func append(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            let weighted = rlbFilter.process(preFilter.process(Double(sample)))
            stepSum += weighted * weighted
            stepCount += 1
            if stepCount == stepSamples {
                stepSums.append(stepSum)
                stepSum = 0
                stepCount = 0
            }
        }
    }

    /// Integrated loudness in LUFS, or `nil` when nothing survived the gates —
    /// silence, or a clip too short to fill one 400 ms block.
    func integratedLUFS() -> Double? {
        let blockSamples = Double(stepSamples * Self.stepsPerBlock)
        guard stepSums.count >= Self.stepsPerBlock else { return nil }

        var meanSquares: [Double] = []
        meanSquares.reserveCapacity(stepSums.count - Self.stepsPerBlock + 1)
        for start in 0...(stepSums.count - Self.stepsPerBlock) {
            let total = stepSums[start..<(start + Self.stepsPerBlock)].reduce(0, +)
            meanSquares.append(total / blockSamples)
        }

        // First gate: drop digital silence, which would otherwise define the
        // relative gate's reference far too low.
        let aboveAbsolute = meanSquares.filter { loudness(of: $0) > Self.absoluteGateLUFS }
        guard !aboveAbsolute.isEmpty else { return nil }

        // Second gate: relative to the ungated average of what is left.
        let ungatedMean = aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)
        let relativeThreshold = loudness(of: ungatedMean) + Self.relativeGateLU
        let gated = aboveAbsolute.filter { loudness(of: $0) > relativeThreshold }
        guard !gated.isEmpty else { return nil }

        let gatedMean = gated.reduce(0, +) / Double(gated.count)
        let result = loudness(of: gatedMean)
        return result.isFinite ? result : nil
    }

    private func loudness(of meanSquare: Double) -> Double {
        meanSquare > 0 ? Self.offset + 10 * log10(meanSquare) : -.infinity
    }
}

extension LoudnessMeter {
    /// How much to change the level by to land on `target`.
    ///
    /// Unlike the ASR chain's makeup gain this may attenuate: a recording louder
    /// than the target should come down, and letting it stay hot would defeat the
    /// point of normalizing at all. The range is wide enough for any real
    /// recording and narrow enough that a mis-measurement cannot produce silence
    /// or a blast.
    static let gainRangeDB: ClosedRange<Double> = -12...18

    static func gainDB(measured: Double?, target: Double) -> Double {
        guard let measured, measured.isFinite else { return 0 }
        return min(max(target - measured, gainRangeDB.lowerBound), gainRangeDB.upperBound)
    }
}

/// Direct-form II transposed biquad, in `Double` because these filters run over
/// the whole recording and the RLB stage has poles very close to the unit circle
/// (`a2 ≈ 0.99007`), where `Float` state accumulates audible error.
private struct Biquad {
    let b0, b1, b2, a1, a2: Double
    private var s1: Double = 0
    private var s2: Double = 0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + s1
        s1 = b1 * x - a1 * y + s2
        s2 = b2 * x - a2 * y
        return y
    }

    /// Stage 1 of K-weighting: the shelf approximating the acoustic effect of a
    /// head in a diffuse field. Coefficients from BS.1770-4, valid at 48 kHz only.
    static let bs1770HighShelf = Biquad(
        b0: 1.53512485958697,
        b1: -2.69169618940638,
        b2: 1.19839281085285,
        a1: -1.69065929318241,
        a2: 0.73248077421585
    )

    /// Stage 2: the RLB high-pass, which discounts low-frequency energy the ear
    /// barely registers as loudness.
    static let bs1770HighPass = Biquad(
        b0: 1.0,
        b1: -2.0,
        b2: 1.0,
        a1: -1.99004745483398,
        a2: 0.99007225036621
    )
}
