//
//  FluidAudioTranscriber.swift
//  Kurn
//
//  On-device multilingual transcription via FluidAudio's batch ASR (Parakeet TDT
//  v3). Unlike Apple's `SFSpeechRecognizer`, this engine supports multilingual
//  recognition: Auto lets the model choose, while an explicitly selected
//  language is forwarded as a decoder hint.
//
//

import AVFoundation
import Foundation
import KurnCore

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioTranscriber: Transcribing {

    /// Transcribe an audio file fully on-device. Auto leaves language selection
    /// to the multilingual model; a supported pinned language is passed to
    /// FluidAudio's decoder so it does not drift into another language.
    func transcribe(
        url: URL,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RawTranscript {
        try await ResourceGuard.requireTranscriptionHeadroom()
        // The model is shared process-wide (see `FluidAudioModelStore`) so it
        // loads once and is reused across recordings, meeting views, and the
        // language-detection pass — not reloaded per instance.
        let manager = try await FluidAudioModelStore.shared.manager()

        // The clip duration bounds the single span (below) and gates progress
        // reporting: FluidAudio only emits progress for clips longer than its
        // internal chunking threshold (`maxModelSamples`, 15 s at 16 kHz).
        let duration = (try? await AVURLAsset(url: url).load(.duration))
            .map(CMTimeGetSeconds) ?? 0

        // Forward FluidAudio's progress stream (0...1) to the caller so the UI
        // bar advances during the on-device pass. Open the stream *before*
        // transcribing so no early ticks are missed, and only when the clip is
        // long enough that the engine will actually run — and finish — a progress
        // session; otherwise we'd leave a dangling session on the shared manager.
        var progressTask: Task<Void, Never>?
        if duration > 15.5 {
            let stream = await manager.transcriptionProgressStream
            progressTask = Task {
                do {
                    for try await fraction in stream {
                        onProgress(min(1, max(0, fraction)))
                    }
                } catch {
                    // A failed session is surfaced by `transcribe` below; the
                    // stream error here just ends progress reporting.
                }
            }
        }
        defer { progressTask?.cancel() }

        let fluidLanguage = language.whisperCode.flatMap(Language.init(rawValue:))
        let languageDescription = fluidLanguage?.rawValue ?? "auto"
        AppLog.transcription.atDebug.debug(
            "fluidAudio: transcribing language=\(languageDescription, privacy: .public)"
        )
        let result: ASRResult
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            try await ResourceGuard.requireTranscriptionHeadroom()
            result = try await manager.transcribe(
                url,
                decoderState: &decoderState,
                language: fluidLanguage
            )
            try await ResourceGuard.requireTranscriptionHeadroom()
        } catch let appError as AppError {
            throw appError
        } catch {
            AppLog.transcription.atError.error("fluidAudio: transcription failed: \(error.localizedDescription, privacy: .public)")
            try ResourceGuard.rethrowIfResourceFailure(error)
            throw AppError.transcriptionFailed(error.localizedDescription)
        }

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return RawTranscript(spans: [], language: "")
        }

        // FluidAudio 0.15.5 exposes token timings. Aggregate its SentencePiece
        // tokens into words so diarization can assign each word to the speaker
        // active at that point. Older/cached results without timings retain the
        // full-clip fallback.
        let words = result.tokenTimings.map(buildWordTimings(from:)) ?? []
        let timedWords = words.map {
            TimedWord(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        let spans = TimedWordSpanBuilder.spans(
            from: timedWords,
            fallbackText: text,
            duration: duration
        )
        return RawTranscript(spans: spans, language: "")
    }
}

#else

/// Built without the FluidAudio package linked: the multilingual on-device engine
/// is unavailable, so callers fall back to `OnDeviceTranscriber` (Apple Speech).
actor FluidAudioTranscriber: Transcribing {
    func transcribe(
        url: URL,
        language: MeetingLanguage,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RawTranscript {
        throw AppError.transcriptionFailed(
            NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        )
    }
}

#endif
