//
//  PipelineStages.swift
//  Kurn
//
//  Protocol seams for each stage of the recognition pipeline so the engine for
//  every stage can be swapped independently. The orchestrator
//  (`TranscriptionService`) resolves an engine per stage from a
//  `PipelineConfiguration` and drives them through these protocols.
//
//  All protocols are `Sendable` value contracts; concrete engines are usually
//  actors wrapping non-`Sendable` audio resources. The intermediate data types
//  (`TranscribedSpan`, `RawTranscript`, `SpeakerTurn`, `Diarizing`) live in
//  `TranscriptionTypes.swift` and are reused as-is.
//

import Foundation

/// Offline audio cleanup applied before transcription/diarization. The returned
/// URL may be the input unchanged (passthrough) or a temporary cleaned copy that
/// the caller owns and should `cleanup` when done.
protocol AudioPreprocessing: Sendable {
    func process(url: URL) async throws -> URL
    func cleanup(_ url: URL) async
}

/// A region of detected speech within a clip, `[start, end)` in seconds.
struct SpeechRegion: Sendable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
}

/// Voice-activity detection: locate the spoken regions of a clip. Used both as a
/// standalone stage and internally by the heuristic diarizer.
protocol VoiceActivityDetecting: Sendable {
    func detectSpeech(url: URL) async -> [SpeechRegion]
}

/// Language detection run before transcription. Implementations return a refined
/// `MeetingLanguage`, or the `hint` unchanged when they can't (or needn't) detect
/// — e.g. the no-op detector that defers to the transcription engine.
protocol LanguageDetecting: Sendable {
    func detect(url: URL, hint: MeetingLanguage) async -> MeetingLanguage
}

/// Turn audio into ordered, timed text spans. Apple Speech, FluidAudio Parakeet,
/// and the chunked Whisper path all conform.
///
/// `onProgress` reports a `0...1` fraction for engines that can (the chunked
/// Whisper upload); single-pass engines ignore it. It's a per-call argument
/// rather than actor state so a shared transcriber actor reused across
/// concurrent recordings never leaks one call's handler into another.
protocol Transcribing: Sendable {
    func transcribe(
        url: URL,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> RawTranscript
}

// `Diarizing` is declared in TranscriptionTypes.swift and is reused unchanged.

/// One engine choice per pipeline stage. Built from `AppSettings` and passed to
/// `TranscriptionService.transcribe`. Defaults match the always-available,
/// no-download engines so a fresh install works offline with no model fetch.
struct PipelineConfiguration: Sendable, Equatable {
    var preprocessing: PreprocessingEngine = .standardDSP
    var vad: VADEngine = .energyThreshold
    var languageDetection: LanguageDetectionEngine = .byTranscriber
    var diarization: DiarizationEngine = .heuristic
    var transcription: TranscriptionEngine = .appleSpeech
}
