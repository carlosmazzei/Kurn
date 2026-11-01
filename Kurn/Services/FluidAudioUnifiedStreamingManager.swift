import AVFoundation
import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

protocol FluidAudioStreamingTimingDiscarding: Actor {
    func discardTokenTimings()
}

actor FluidAudioUnifiedStreamingManager: StreamingAsrManager {
    typealias Loader = @Sendable (MeetingLanguage) async throws -> any StreamingAsrManager

    private let language: MeetingLanguage
    private let isInstalled: @Sendable () -> Bool
    private let load: Loader
    private let audioConverter = AudioConverter()
    private var manager: (any StreamingAsrManager)?
    private var pendingSamples: [Float] = []
    private var cachedPartialText = ""
    private var externalCallback: (@Sendable (String) -> Void)?

    init(
        language: MeetingLanguage,
        isInstalled: @escaping @Sendable () -> Bool = { FluidAudioASRModelRuntime.isUnifiedStreamingInstalled },
        load: @escaping Loader = FluidAudioUnifiedStreamingManager.loadLocal
    ) {
        self.language = language
        self.isInstalled = isInstalled
        self.load = load
    }

    var displayName: String { FluidAudioASRModel.nemotronUnified.displayName }

    func loadModels() async throws {
        try FluidAudioRuntimePolicy.validate(model: .nemotronUnified, language: language, isInstalled: isInstalled())
        guard manager == nil else { return }
        manager = try await load(language)
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer) throws {
        try StreamingAsrUtils.appendAudio(buffer, using: audioConverter, to: &pendingSamples)
    }

    func processBufferedAudio() async throws {
        guard let manager, !pendingSamples.isEmpty else { return }
        let samples = pendingSamples
        pendingSamples.removeAll()
        try await manager.appendAudio(Self.makeBuffer(samples))
        try await Self.processBufferedAudio(using: manager)
        updatePartial(await manager.getPartialTranscript())
    }

    func finish() async throws -> String {
        guard let manager else { throw ASRError.notInitialized }
        try await processBufferedAudio()
        let text: String
        do {
            text = try await manager.finish()
        } catch {
            await Self.discardTokenTimings(from: manager)
            throw error
        }
        await Self.discardTokenTimings(from: manager)
        updatePartial(text)
        return text
    }

    static func processBufferedAudio(using manager: any StreamingAsrManager) async throws {
        do {
            try await manager.processBufferedAudio()
        } catch {
            await discardTokenTimings(from: manager)
            throw error
        }
        await discardTokenTimings(from: manager)
    }

    static func discardTokenTimings(from manager: any StreamingAsrManager) async {
        if let manager = manager as? any FluidAudioStreamingTimingDiscarding {
            await manager.discardTokenTimings()
        }
    }

    func reset() async throws {
        pendingSamples.removeAll()
        cachedPartialText = ""
        try await manager?.reset()
    }

    func cleanup() async {
        let previous = manager
        manager = nil
        pendingSamples.removeAll()
        cachedPartialText = ""
        externalCallback = nil
        await previous?.cleanup()
    }

    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {
        externalCallback = callback
    }

    func getPartialTranscript() -> String { cachedPartialText }

    private func updatePartial(_ text: String) {
        cachedPartialText = text
        externalCallback?(text)
    }

    private static func makeBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else {
            throw ASRError.invalidAudioData
        }
        channel.update(from: samples, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    static func loadLocal(language: MeetingLanguage) async throws -> any StreamingAsrManager {
        guard let unifiedLanguage = FluidAudioASRModelRuntime.unifiedLanguage(for: language) else {
            throw AppError.transcriptionLanguageUnsupported(language, .fluidAudioParakeet)
        }
        return try await loadLocal(unifiedLanguage: unifiedLanguage)
    }
}
#endif
