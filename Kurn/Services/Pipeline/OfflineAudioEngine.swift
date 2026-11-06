import AVFoundation

enum OfflineAudioEngine {
    static func make(outputFormat: AVAudioFormat, maxFrames: AVAudioFrameCount) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: maxFrames)
        return engine
    }
}
