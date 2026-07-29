//
//  SpeechLevelMeterTests.swift
//  KurnTests
//
//  The gain decision and the level measurement are pure, so they are tested
//  without touching audio files or AVFoundation at all.
//

import Foundation
import Testing
@testable import Kurn

struct SpeechLevelMeterTests {

    // MARK: - Gain decision

    @Test func quietRecordingIsLiftedTowardTheTarget() {
        // Speech 20 dB under target with plenty of headroom: the full lift is
        // available, capped only by the 18 dB ceiling.
        let gain = SpeechLevel.makeupGainDB(peakDBFS: -25, speechRMSDBFS: -40)
        #expect(gain == 18)
    }

    @Test func healthyRecordingIsLeftAlone() {
        let gain = SpeechLevel.makeupGainDB(peakDBFS: -6, speechRMSDBFS: -20)
        #expect(gain == 0)
    }

    /// The regression this whole change exists for: the chain used to add a fixed
    /// +11 dB (a +8 dB makeup on top of the limiter's +3 dB pre-gain) to *every*
    /// recording, including ones already close to full scale.
    @Test func hotRecordingIsNeverAmplified() {
        let gain = SpeechLevel.makeupGainDB(peakDBFS: -1, speechRMSDBFS: -12)
        #expect(gain == 0)
    }

    @Test func headroomCapsTheLiftBelowWhatTheTargetWouldWant() {
        // Target wants +15 dB, but the peak only has 5 dB of room before the
        // ceiling — headroom wins.
        let gain = SpeechLevel.makeupGainDB(peakDBFS: -8, speechRMSDBFS: -35)
        #expect(gain == 5)
    }

    @Test func silenceGetsNoGain() {
        #expect(SpeechLevel.makeupGainDB(peakDBFS: -.infinity, speechRMSDBFS: -.infinity) == 0)
        #expect(SpeechLevel.silent.makeupGainDB == 0)
    }

    @Test func gainNeverLeavesTheAllowedRange() {
        for peak in stride(from: Float(-80), through: 0, by: 7) {
            for speech in stride(from: Float(-90), through: 0, by: 7) {
                let gain = SpeechLevel.makeupGainDB(peakDBFS: peak, speechRMSDBFS: speech)
                #expect(SpeechLevel.gainRangeDB.contains(gain))
            }
        }
    }

    // MARK: - Measurement

    @Test func measuresPeakAndRMSOfASteadyTone() {
        var meter = SpeechLevelMeter()
        append(&meter, tone(amplitude: 0.5, seconds: 1.0))
        let level = meter.finish()

        // A sine's RMS is amplitude / sqrt(2).
        #expect(abs(level.speechRMS - Float(0.5 / 2.0.squareRoot())) < 0.01)
        #expect(abs(level.peak - 0.5) < 0.01)
    }

    /// The reason the meter exists rather than a plain overall RMS: a meeting is
    /// mostly pauses, and averaging those in would report it as quiet and then
    /// lift the talking until it clips.
    @Test func silenceIsExcludedFromTheSpeechAverage() {
        var meter = SpeechLevelMeter()
        append(&meter, tone(amplitude: 0.5, seconds: 1.0))
        append(&meter, [Float](repeating: 0, count: 16_000))
        let level = meter.finish()

        let toneRMS = Float(0.5 / 2.0.squareRoot())
        // Averaging everything would land near toneRMS / sqrt(2) ≈ 0.25.
        #expect(abs(level.speechRMS - toneRMS) < 0.01)
        #expect(level.speechRMS > 0.30)
    }

    @Test func bufferBoundariesDoNotChangeTheResult() {
        let samples = tone(amplitude: 0.4, seconds: 0.5)

        var whole = SpeechLevelMeter()
        append(&whole, samples)

        // 100 is deliberately not a multiple of the 320-sample frame, so every
        // chunk boundary lands mid-frame and exercises the carry buffer.
        var chunked = SpeechLevelMeter()
        var index = 0
        while index < samples.count {
            let end = min(index + 100, samples.count)
            append(&chunked, Array(samples[index..<end]))
            index = end
        }

        let a = whole.finish()
        let b = chunked.finish()
        #expect(abs(a.speechRMS - b.speechRMS) < 1e-5)
        #expect(abs(a.peak - b.peak) < 1e-6)
    }

    @Test func pureSilenceMeasuresAsSilent() {
        var meter = SpeechLevelMeter()
        append(&meter, [Float](repeating: 0, count: 16_000))
        let level = meter.finish()

        #expect(level.peak == 0)
        #expect(level.speechRMS == 0)
        #expect(level.speechRMSDBFS == -.infinity)
    }

    @Test func emptyInputIsSilent() {
        let meter = SpeechLevelMeter()
        #expect(meter.finish() == SpeechLevel.silent)
    }

    // MARK: - Helpers

    private func append(_ meter: inout SpeechLevelMeter, _ samples: [Float]) {
        samples.withUnsafeBufferPointer { meter.append($0) }
    }

    private func tone(amplitude: Float, seconds: Double, hz: Double = 440, sampleRate: Double = 16_000) -> [Float] {
        let count = Int(sampleRate * seconds)
        let omega = 2.0 * Double.pi * hz
        return (0..<count).map { Float(sin(omega * Double($0) / sampleRate)) * amplitude }
    }
}
