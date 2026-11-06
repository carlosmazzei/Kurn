import AVFoundation
import Foundation
import KurnCore

final class VADAudioBufferReader {
    static let bufferSize = 4096
    let expectedFrames: Int
    private let input: AVAudioFile
    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var finished = false

    init(url: URL, sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AppError.audioError(NSLocalizedString("error.audio_cleanup", comment: "Audio loading failed"))
        }
        input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        guard let output = OfflineAudioRenderer.monoFormat(sampleRate: sampleRate) else {
            throw AppError.audioError(NSLocalizedString("error.audio_cleanup", comment: "Audio loading failed"))
        }
        engine = try OfflineAudioEngine.make(outputFormat: output, maxFrames: AVAudioFrameCount(Self.bufferSize))
        guard input.length > 0, format.sampleRate > 0 else {
            expectedFrames = 0
            return
        }
        expectedFrames = Int(Double(input.length) * (sampleRate / format.sampleRate))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(Self.bufferSize))
            guard buffer != nil else {
                throw AppError.audioError(NSLocalizedString("error.audio_cleanup", comment: "Audio loading failed"))
            }
            player.scheduleFile(input, at: nil, completionHandler: nil)
            player.play()
        } catch {
            player.stop()
            engine.stop()
            throw error
        }
    }

    deinit {
        player.stop()
        engine.stop()
    }

    func next() throws -> [Float]? {
        try Task.checkCancellation()
        guard !finished, let buffer else { return nil }
        while engine.manualRenderingSampleTime < expectedFrames {
            let remaining = expectedFrames - Int(engine.manualRenderingSampleTime)
            let status = try engine.renderOffline(AVAudioFrameCount(min(Self.bufferSize, remaining)), to: buffer)
            guard status == .success else {
                finished = true
                return nil
            }
            if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
                return Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            }
        }
        finished = true
        return nil
    }
}
