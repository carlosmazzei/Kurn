//
//  PlaybackTuning.swift
//  Kurn
//
//  The DSP settings the enhanced listening copy is rendered with.
//
//  Kept as a value type rather than constants scattered through the renderer so
//  the numbers can be asserted directly. That matters here because the app already
//  has a *second*, differently-tuned chain — `AudioPreprocessor`, aimed at a
//  recogniser — and the two must not converge by accident. The ASR chain lifts by
//  a measured makeup gain into a limiter, which maximises what a machine can
//  extract; applied to a human ear the same settings sound pumped and harsh.
//

import Foundation

struct PlaybackTuning: Equatable, Sendable {

    /// A peaking/shelving EQ band.
    struct Band: Equatable, Sendable {
        var frequency: Float
        var bandwidth: Float
        var gain: Float
    }

    /// Removes rumble, handling noise and HVAC below the voice.
    var highPassHz: Float

    /// Presence lift for consonant clarity. Deliberately wider and gentler than
    /// the ASR chain's, and centred above the vowel formants rather than on them —
    /// a narrow loud bell at 2.5 kHz reads as nasal over headphones.
    var presence: Band

    var compressorThresholdDB: Float
    /// Larger headroom means a softer knee and a lower effective ratio. This is
    /// the single parameter most responsible for the result not sounding pumped.
    var compressorHeadRoomDB: Float
    /// Fast enough to catch a shouted word, slow enough that consonant transients
    /// pass intact. A recogniser does not care about transients; an ear does.
    var compressorAttack: Float
    /// Spans inter-syllable gaps so gain does not wobble at syllable rate — that
    /// wobble is exactly what "pumping" sounds like.
    var compressorRelease: Float

    /// `1.0` disables the downward expander. Never gate for listening: a gate
    /// chews word tails, and the quiet far-table voice this feature exists to
    /// rescue is precisely what a gate would remove.
    var expansionRatio: Float
    var expansionThresholdDB: Float

    /// Restores roughly what the compression took off. Half the ASR chain's.
    var makeupGainDB: Float

    /// The limiter is a seatbelt, not a loudness stage. Any *constant* limiting is
    /// the harshness this tuning exists to avoid, which is why the pre-gain is 0
    /// where the ASR chain used to carry +3.
    var limiterPreGainDB: Float
    var limiterAttack: Float
    var limiterDecay: Float

    /// Integrated loudness the render normalizes to, in LUFS. -16 is the podcast
    /// convention, and the app is mono.
    var targetLUFS: Double

    // NOTE: the dry/wet mix ratio belongs here too — a denoised signal wants a
    // little of the original back to mask its artefacts and restore room tone —
    // but it arrives with the denoiser, not before it. Carrying the number now
    // would mean a tuning parameter, and a test asserting it, that no rendered
    // sample is affected by. See `Services/Enhancement/SpeechEnhancer.swift`.

    static let listening = PlaybackTuning(
        highPassHz: 80,
        presence: Band(frequency: 4000, bandwidth: 1.2, gain: 3),
        compressorThresholdDB: -28,
        compressorHeadRoomDB: 8,
        compressorAttack: 0.010,
        compressorRelease: 0.250,
        expansionRatio: 1.0,
        expansionThresholdDB: -100,
        makeupGainDB: 4,
        limiterPreGainDB: 0,
        limiterAttack: 0.004,
        limiterDecay: 0.060,
        targetLUFS: -16
    )
}
