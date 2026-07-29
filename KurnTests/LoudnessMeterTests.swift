//
//  LoudnessMeterTests.swift
//  KurnTests
//
//  These assert *invariants*, not absolute LUFS values. Checking a number this
//  implementation produced against a number this implementation computed would be
//  circular; the properties below hold for any correct BS.1770 meter and fail for
//  most incorrect ones.
//

import Foundation
import Testing
@testable import Kurn

struct LoudnessMeterTests {

    /// Loudness is a level measurement, so halving the amplitude must move it by
    /// exactly -6.02 LU. This catches a filter with the wrong gain, a mean-square
    /// that is actually a mean-magnitude, and a missing square root — none of
    /// which an absolute-value test would distinguish from a calibration slip.
    @Test func halvingAmplitudeLowersLoudnessBySixLU() throws {
        let loud = try #require(measure(amplitude: 0.4))
        let quiet = try #require(measure(amplitude: 0.2))
        #expect(abs((loud - quiet) - 6.0206) < 0.01)
    }

    /// The reason the gates exist: a meeting is mostly pauses, and if silence
    /// counted toward the average every recording would measure quiet and then be
    /// normalized until the talking parts clip.
    @Test func trailingSilenceDoesNotChangeTheMeasurement() throws {
        let speechOnly = try #require(measure(amplitude: 0.3, seconds: 4))
        let padded = try #require(measure(amplitude: 0.3, seconds: 4, silenceSeconds: 6))
        #expect(abs(speechOnly - padded) < 0.5)
    }

    @Test func silenceHasNoMeasurableLoudness() {
        var meter = LoudnessMeter()
        let silence = [Float](repeating: 0, count: 48_000)
        silence.withUnsafeBufferPointer { meter.append($0) }
        #expect(meter.integratedLUFS() == nil)
    }

    /// Shorter than one 400 ms block: there is nothing to report, and reporting
    /// something would let the renderer apply a gain derived from noise.
    @Test func clipShorterThanOneBlockMeasuresNothing() {
        var meter = LoudnessMeter()
        let short = STFTTests.noise(count: 4_800, amplitude: 0.5)
        short.withUnsafeBufferPointer { meter.append($0) }
        #expect(meter.integratedLUFS() == nil)
    }

    // MARK: - Gain

    @Test func gainMovesMeasuredLoudnessToTheTarget() {
        #expect(abs(LoudnessMeter.gainDB(measured: -30, target: -16) - 14) < 1e-9)
    }

    /// Unlike the ASR chain's makeup gain, this one may attenuate — a recording
    /// louder than the target has to come down or normalizing achieves nothing.
    @Test func gainAttenuatesARecordingLouderThanTheTarget() {
        #expect(LoudnessMeter.gainDB(measured: -8, target: -16) == -8)
    }

    @Test func gainIsClampedAndSafeWithoutAMeasurement() {
        #expect(LoudnessMeter.gainDB(measured: -90, target: -16) == LoudnessMeter.gainRangeDB.upperBound)
        #expect(LoudnessMeter.gainDB(measured: 0, target: -16) == LoudnessMeter.gainRangeDB.lowerBound)
        #expect(LoudnessMeter.gainDB(measured: nil, target: -16) == 0)
        #expect(LoudnessMeter.gainDB(measured: -.infinity, target: -16) == 0)
    }

    // MARK: - Helpers

    private func measure(amplitude: Float, seconds: Int = 3, silenceSeconds: Int = 0) -> Double? {
        var meter = LoudnessMeter()
        let rate = Int(LoudnessMeter.requiredSampleRate)
        let signal = STFTTests.noise(count: rate * seconds, amplitude: amplitude)
        signal.withUnsafeBufferPointer { meter.append($0) }
        if silenceSeconds > 0 {
            let silence = [Float](repeating: 0, count: rate * silenceSeconds)
            silence.withUnsafeBufferPointer { meter.append($0) }
        }
        return meter.integratedLUFS()
    }
}

struct PlaybackTuningTests {

    /// These lock the *intent* of the listening chain against the ASR chain in
    /// `AudioPreprocessor.configureDynamics`, which is tuned to maximise what a
    /// recogniser extracts and sounds pumped and harsh to an ear. The literals
    /// from that chain appear here on purpose, so a future edit that copies them
    /// across fails a test instead of shipping.
    @Test func listeningChainIsGentlerThanTheASRChain() {
        let tuning = PlaybackTuning.listening

        // The ASR chain carries +3 dB of limiter pre-gain, which keeps it in
        // near-constant gain reduction. Here the limiter is a seatbelt only.
        #expect(tuning.limiterPreGainDB == 0)

        // The ASR chain's makeup is derived per recording but capped at 18 dB;
        // the listening chain's is a fixed, modest restoration.
        #expect(tuning.makeupGainDB <= 6)

        // Never gate for listening: the quiet far-table voice this feature exists
        // to rescue is exactly what an expander would remove.
        #expect(tuning.expansionRatio == 1)
        #expect(tuning.expansionThresholdDB <= -100)

        // Wider and quieter than the ASR chain's +4 dB at bandwidth 1.0, and
        // above the vowel formants rather than on them.
        #expect(tuning.presence.gain < 4)
        #expect(tuning.presence.bandwidth > 1.0)
        #expect(tuning.presence.frequency > 2500)
    }

    @Test func targetIsThePodcastConvention() {
        #expect(PlaybackTuning.listening.targetLUFS == -16)
        #expect(PlaybackTuning.listening.highPassHz > 60 && PlaybackTuning.listening.highPassHz < 120)
    }
}
