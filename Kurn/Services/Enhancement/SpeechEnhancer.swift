//
//  SpeechEnhancer.swift
//  Kurn
//
//  Seam for the neural denoise stage of the enhanced listening copy.
//
//  The stage is optional by design, and the renderer treats its absence as normal
//  rather than as a failure. Two reasons:
//
//  1. The model is converted from DPDFNet's ONNX release by `Tools/dpdfnet/`,
//     which needs macOS and `coremltools`. Until someone runs it and drops the
//     `.mlpackage` into the bundle, the app must still build, test and work.
//  2. Denoising is the *smaller* half of what makes a far-table voice audible.
//     It removes the noise around a quiet talker without making the talker any
//     louder — that is the compressor's and the loudness normalization's job.
//     A DSP-only enhanced copy is already worth listening to.
//
//  So `SpeechEnhancer.shared.enhance` returning `nil` is a supported outcome, not
//  an error path.
//
//  Nothing calls this yet, deliberately. `PlaybackEnhancementRenderer` renders
//  through an `AVAudioEngine` chain, and a frame-by-frame model does not drop
//  into one — it needs its own decode/enhance/mix pass either side of it. Wiring
//  that pass, along with the dry/wet ratio it needs (see `PlaybackTuning`),
//  belongs in the same change as the inference loop, where it can be run against
//  a real model instead of against a stub that always returns `nil`.
//

import Foundation
import os

/// Removes background noise from mono 16 kHz speech.
protocol SpeechEnhancing: Sendable {
    /// Enhanced samples, or `nil` when no model is available. Never throws: a
    /// missing or broken model degrades the render, it does not fail it.
    func enhance(samples: [Float]) async -> [Float]?
}

/// Description of a converted model, emitted alongside the `.mlpackage` by
/// `Tools/dpdfnet/convert.py`.
///
/// The tensor names, bin count and state shape are *discovered* from the ONNX
/// graph at conversion time and written here, rather than hardcoded in Swift from
/// reading the model's documentation. Guessing them would produce a model that
/// loads and runs and returns plausible-sounding garbage — the same class of
/// silent failure the WPE port guards against with a parity test.
struct SpeechEnhancerModelConfig: Codable, Sendable, Equatable {
    /// Base name of the `.mlmodelc` in the app bundle.
    var modelName: String
    /// Sample rate the model was trained at. The renderer resamples to this.
    var sampleRate: Double
    /// STFT window length in samples.
    var frameSize: Int
    /// STFT hop in samples.
    var hopSize: Int
    /// Frequency bins the graph consumes and produces (`frameSize / 2 + 1`).
    var binCount: Int
    /// Flattened size of the recurrent state carried between frames.
    var stateSize: Int
    /// Input tensor names, in the order the graph declares them.
    var spectrumInput: String
    var stateInput: String
    /// Output tensor names.
    var spectrumOutput: String
    var stateOutput: String

    /// Name of the JSON sidecar in the bundle.
    static let resourceName = "dpdfnet"

    /// Load the config shipped next to the model, or `nil` when the conversion
    /// has not been run for this build.
    static func bundled(in bundle: Bundle = .main) -> SpeechEnhancerModelConfig? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(SpeechEnhancerModelConfig.self, from: data) else {
            AppLog.transcription.atError.error("enhance: found \(resourceName, privacy: .public).json but could not decode it")
            return nil
        }
        return config
    }
}

/// Loads the converted DPDFNet model once and runs it frame by frame.
///
/// `actor` with a shared instance, mirroring `FluidAudioModelStore`: CoreML
/// compiles its artifacts on first load, and two concurrent renders must not pay
/// that twice or race each other's state.
actor SpeechEnhancer: SpeechEnhancing {
    static let shared = SpeechEnhancer()

    private var resolved = false
    private var config: SpeechEnhancerModelConfig?

    /// Whether a model is installed. Lets the UI explain that enhancement is
    /// running DSP-only rather than silently doing less than the user expects.
    func isModelAvailable() -> Bool {
        resolveConfig() != nil
    }

    func enhance(samples: [Float]) async -> [Float]? {
        guard resolveConfig() != nil else { return nil }
        // The inference loop is written once the conversion has produced a model
        // and its config, because that is when the tensor shapes stop being
        // assumptions. Until then this reports "no model" and the renderer runs
        // its DSP chain alone, which is a good result rather than a broken one.
        return nil
    }

    private func resolveConfig() -> SpeechEnhancerModelConfig? {
        if !resolved {
            resolved = true
            config = SpeechEnhancerModelConfig.bundled()
            if config == nil {
                AppLog.transcription.atNotice.notice("enhance: no speech-enhancement model installed, using DSP only")
            }
        }
        return config
    }
}
