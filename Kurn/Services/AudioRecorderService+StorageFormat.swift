//
//  AudioRecorderService+StorageFormat.swift
//  Kurn
//
//  The fixed format every recording is stored in, independent of the
//  microphone route. See CLAUDE.md, "Audio storage format".
//

import AVFoundation

extension AudioRecorderService {
    /// Sample rate every recording is stored at, regardless of what the
    /// microphone route negotiates (typically 48kHz built-in, 16kHz Bluetooth
    /// HFP). Speech occupies roughly 80Hz–8kHz, so 24kHz mono — a 12kHz band —
    /// is transparent for voice even at the 2x playback `AudioPlayerService`
    /// offers, while every machine consumer of the audio resamples to 16kHz
    /// anyway (`AudioPreprocessor`, `DiarizationPreprocessor`, `VADAudioLoader`,
    /// `WhisperCppTranscriber`, and the ASR frameworks internally). Storing the
    /// mic's native rate therefore spent bits on a band nothing reads.
    /// `nonisolated` because this type is `@MainActor`, which its statics would
    /// otherwise inherit — and the engine setup (`beginEngine`) and
    /// `RecordingCompactor` both read these from outside the main actor.
    nonisolated static let storageSampleRate: Double = 24_000
    /// Recordings are always mono: diarization and ASR both downmix, and the
    /// second channel of a stereo external mic doubles the file for nothing.
    nonisolated static let storageChannelCount: AVAudioChannelCount = 1

    /// The format buffers are converted to before being encoded. Non-nil for
    /// every sample rate/channel pair we pass, but `AVAudioFormat`'s initializer
    /// is failable, so callers treat `nil` as a setup failure.
    nonisolated static var storageProcessingFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: storageSampleRate,
            channels: storageChannelCount,
            interleaved: false
        )
    }
}
