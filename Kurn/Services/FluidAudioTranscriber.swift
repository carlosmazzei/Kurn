//
//  FluidAudioTranscriber.swift
//  Kurn
//
//  On-device multilingual transcription via FluidAudio's batch ASR (Parakeet TDT
//  v3). Unlike Apple's `SFSpeechRecognizer` — which requires a fixed locale and
//  cannot detect the spoken language — this engine detects the language from the
//  audio itself, so a meeting recorded in English on a pt-BR device still
//  transcribes in English. Used for the post-recording transcript when the
//  meeting language is "Auto"; pinned languages stay on `OnDeviceTranscriber`.
//
//

import AVFoundation
import Foundation

#if canImport(FluidAudio)
import FluidAudio

actor FluidAudioTranscriber: Transcribing {

    /// Transcribe an audio file fully on-device with automatic language
    /// detection. `language` is accepted for parity with `OnDeviceTranscriber`;
    /// the multilingual model detects the language from the audio, so no locale
    /// is forced.
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

        AppLog.transcription.atDebug.debug("fluidAudio: transcribing (auto language detection)")
        let text: String
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            try await ResourceGuard.requireTranscriptionHeadroom()
            let result = try await manager.transcribe(url, decoderState: &decoderState)
            try await ResourceGuard.requireTranscriptionHeadroom()
            text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let appError as AppError {
            throw appError
        } catch {
            AppLog.transcription.atError.error("fluidAudio: transcription failed: \(error.localizedDescription, privacy: .public)")
            try ResourceGuard.rethrowIfResourceFailure(error)
            throw AppError.transcriptionFailed(error.localizedDescription)
        }

        guard !text.isEmpty else {
            return RawTranscript(spans: [], language: "")
        }

        // The clip duration bounds the single span so downstream diarization
        // fusion has a sensible time range to attribute it to.
        //
        // TODO: once the ASRResult per-token/word timing API is confirmed on
        // macOS, split into timed spans for finer speaker attribution. The full
        // text as one span keeps this compiling and correct for single-speaker
        // recordings; multi-speaker clips get coarser attribution until then.
        let span = TranscribedSpan(text: text, start: 0, end: duration, confidence: nil)
        return RawTranscript(spans: [span], language: "")
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
