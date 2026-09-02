//
//  PlaybackEnhancementRenderer.swift
//  Kurn
//
//  Renders the enhanced listening copy of a recording in its protected derived
//  directory, with neural denoising, loudness normalization, a speech EQ and a
//  gentle compressor already baked in.
//
//  Doing this offline rather than in the player is what keeps the change small.
//  `AudioPlayerService` stays on `AVAudioPlayer` and only picks which URL to open;
//  no realtime graph, no ring buffers, no reimplemented seek, no interruption
//  recovery. The cost is disk and a one-time wait, both of which the user controls
//  — copies are generated on demand and deletable from Settings.
//
//  Two passes, because loudness cannot be known in advance. The first measures
//  integrated loudness at 48 kHz (the only rate BS.1770's coefficients are valid
//  at); the second applies the resulting gain **at the input**, ahead of the EQ and
//  compressor. That order matters: with the level normalized first, the
//  compressor's fixed threshold means the same thing for every recording in the
//  library, which it cannot when the input level is arbitrary.
//
//  Decoding goes through `OfflineAudioRenderer` because `AVAudioFile.read` and
//  `AVAudioConverter` both fail on the app's own AAC files on device — see that
//  type's header.
//

import AudioToolbox
import AVFoundation
import Foundation
import KurnCore
import os

struct PlaybackEnhancementRenderer: Sendable {

    /// Bump when the tuning changes. Copies stamped with an older version are
    /// regenerated rather than served, so a tuning fix reaches recordings the user
    /// already enhanced.
    static let currentVersion = 3

    /// Output rate. Matches `AudioRecorderService.storageSampleRate`, so the copy
    /// keeps the original's full bandwidth.
    static let outputSampleRate: Double = 24_000
    /// Higher than the ASR cleanup's 32 kbps: this copy is for ears, and it has
    /// already been through one lossy generation.
    private static let outputBitRate = 64_000

    var tuning: PlaybackTuning = .listening
    var enhancer: any SpeechEnhancing = SpeechEnhancer.shared

    /// Render the enhanced copy for `fileName` and move it into the enhanced
    /// directory. Returns its size in bytes.
    ///
    /// Throws only for conditions that should abort the whole operation:
    /// cancellation, resource exhaustion, and a source that cannot be read.
    func render(
        fileName: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Int64 {
        try await ResourceGuard.requireTranscriptionHeadroom()
        // H8 PR 17: global weight budget shared with the other pipeline
        // stages — see `ResourceScheduler`'s header.
        try await ResourceScheduler.shared.acquire(weight: ResourceWorkKind.enhancement.weight)
        defer { Task { await ResourceScheduler.shared.release(weight: ResourceWorkKind.enhancement.weight) } }
        onProgress?(0)
        let started = Date()
        let sourceURL = AudioFileStore.resolveURL(fileName: fileName)

        let failure = AppError.audioError(
            NSLocalizedString("error.audio_enhancement", comment: "Enhanced audio render failed")
        )

        let neuralURL = try await renderNeuralMix(
            from: sourceURL,
            failure: failure,
            onProgress: { onProgress?(0.85 * $0) }
        )
        defer {
            if let neuralURL { try? FileManager.default.removeItem(at: neuralURL) }
        }
        let chainInputURL = neuralURL ?? sourceURL

        let loudness = try await measureLoudness(
            url: chainInputURL,
            failure: failure,
            onProgress: { onProgress?(0.85 + 0.07 * $0) }
        )
        let gainDB = LoudnessMeter.gainDB(measured: loudness, target: tuning.targetLUFS)
        AppLog.recorder.atInfo.info("enhance: \(fileName, privacy: .public) measured=\(loudness ?? .nan, privacy: .public)LUFS gain=\(gainDB, privacy: .public)dB")
        try Task.checkCancellation()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kurn_enh_\(UUID().uuidString).m4a")
        var moved = false
        defer {
            if !moved { try? FileManager.default.removeItem(at: tempURL) }
        }

        try await renderChain(
            from: chainInputURL,
            to: tempURL,
            inputGainDB: Float(gainDB),
            failure: failure,
            onProgress: { onProgress?(0.92 + 0.07 * $0) }
        )

        let size = try install(tempURL: tempURL, fileName: fileName, failure: failure)
        moved = true
        onProgress?(1)
        AppLog.recorder.atNotice.notice("enhance: \(fileName, privacy: .public) rendered in \(Date().timeIntervalSince(started), privacy: .public)s (\(size, privacy: .public) bytes)")
        return size
    }

    // MARK: - Pass 1: loudness

    private func measureLoudness(
        url: URL,
        failure: AppError,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> Double? {
        guard let format = OfflineAudioRenderer.monoFormat(
            sampleRate: LoudnessMeter.requiredSampleRate
        ) else { throw failure }

        let renderer = OfflineAudioRenderer(
            outputFormat: format,
            failure: failure,
            logLabel: "enhance.loudness"
        )

        var meter = LoudnessMeter()
        try await renderer.render(url: url, onProgress: onProgress) { buffer in
            try Task.checkCancellation()
            guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            meter.append(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        return meter.integratedLUFS()
    }

    // MARK: - Pass 2: the chain

    private func renderChain(
        from sourceURL: URL,
        to outURL: URL,
        inputGainDB: Float,
        failure: AppError,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let outputFormat = OfflineAudioRenderer.monoFormat(sampleRate: Self.outputSampleRate) else {
            throw failure
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: Self.outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: Self.outputBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: settings)

        // Held outside the chain builder so `afterStart` can reach their audio
        // units: `engine.start()` is what initializes them, so parameters can only
        // be written once the renderer has started.
        let dynamics = AVAudioUnitEffect(audioComponentDescription: Self.effect(kAudioUnitSubType_DynamicsProcessor))
        let limiter = AVAudioUnitEffect(audioComponentDescription: Self.effect(kAudioUnitSubType_PeakLimiter))
        let tuning = tuning

        let renderer = OfflineAudioRenderer(
            outputFormat: outputFormat,
            buildChain: { engine, player, inputFormat in
                let eq = Self.makeEQ(tuning: tuning, inputGainDB: inputGainDB)
                engine.attach(eq)
                engine.attach(dynamics)
                engine.attach(limiter)
                engine.connect(player, to: eq, format: inputFormat)
                engine.connect(eq, to: dynamics, format: inputFormat)
                engine.connect(dynamics, to: limiter, format: inputFormat)
                engine.connect(limiter, to: engine.mainMixerNode, format: inputFormat)
            },
            afterStart: { _ in
                Self.configure(dynamics.audioUnit, tuning: tuning)
                Self.configure(limiter: limiter.audioUnit, tuning: tuning)
            },
            failure: failure,
            logLabel: "enhance"
        )

        try await renderer.render(url: sourceURL, onProgress: onProgress) { buffer in
            try Task.checkCancellation()
            try outFile.write(from: buffer)
        }
    }

    // MARK: - Install

    /// Stamp the protection class *before* the file lands in the protected tree,
    /// so it is never briefly readable without the passcode — the same sequence
    /// `RecordingCompactor` uses when swapping a recording in place.
    private func install(tempURL: URL, fileName: String, failure: AppError) throws -> Int64 {
        let size = Int64((try? tempURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard size > 0 else { throw failure }

        RecordingProtection.apply(to: tempURL)
        try AudioFileStore.ensureEnhancedDirectory()
        let destination = AudioFileStore.enhancedURL(fileName: fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        // `moveItem` does not promise to carry the attribute across.
        RecordingProtection.apply(to: destination)
        return size
    }

    // MARK: - Units

    private static func makeEQ(tuning: PlaybackTuning, inputGainDB: Float) -> AVAudioUnitEQ {
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        let highPass = eq.bands[0]
        highPass.filterType = .highPass
        highPass.frequency = tuning.highPassHz
        highPass.bypass = false

        let presence = eq.bands[1]
        presence.filterType = .parametric
        presence.frequency = tuning.presence.frequency
        presence.bandwidth = tuning.presence.bandwidth
        presence.gain = tuning.presence.gain
        presence.bypass = false

        // The loudness correction rides here, at the head of the chain, so the
        // compressor below always sees a consistent input level.
        eq.globalGain = inputGainDB
        return eq
    }

    private static func effect(_ subType: OSType) -> AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    private static func configure(_ unit: AudioUnit, tuning: PlaybackTuning) {
        setParam(unit, kDynamicsProcessorParam_Threshold, tuning.compressorThresholdDB)
        setParam(unit, kDynamicsProcessorParam_HeadRoom, tuning.compressorHeadRoomDB)
        setParam(unit, kDynamicsProcessorParam_AttackTime, tuning.compressorAttack)
        setParam(unit, kDynamicsProcessorParam_ReleaseTime, tuning.compressorRelease)
        setParam(unit, kDynamicsProcessorParam_ExpansionRatio, tuning.expansionRatio)
        setParam(unit, kDynamicsProcessorParam_ExpansionThreshold, tuning.expansionThresholdDB)
        setParam(unit, kDynamicsProcessorParam_OverallGain, tuning.makeupGainDB)
    }

    private static func configure(limiter unit: AudioUnit, tuning: PlaybackTuning) {
        setParam(unit, kLimiterParam_PreGain, tuning.limiterPreGainDB)
        setParam(unit, kLimiterParam_AttackTime, tuning.limiterAttack)
        setParam(unit, kLimiterParam_DecayTime, tuning.limiterDecay)
    }

    private static func setParam(
        _ unit: AudioUnit,
        _ id: AudioUnitParameterID,
        _ value: AudioUnitParameterValue
    ) {
        _ = AudioUnitSetParameter(unit, id, kAudioUnitScope_Global, 0, value, 0)
    }
}
