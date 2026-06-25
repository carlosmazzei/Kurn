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

actor FluidAudioTranscriber {

    /// Lazily loaded and reused across recordings — model load is expensive.
    private var manager: AsrManager?

    /// Transcribe an audio file fully on-device with automatic language
    /// detection. `language` is accepted for parity with `OnDeviceTranscriber`;
    /// the multilingual model detects the language from the audio, so no locale
    /// is forced.
    func transcribe(url: URL, language: MeetingLanguage) async throws -> RawTranscript {
        let manager = try await loadedManager()

        AppLog.transcription.atDebug.debug("fluidAudio: transcribing (auto language detection)")
        let text: String
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(url, decoderState: &decoderState)
            text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            AppLog.transcription.atError.error("fluidAudio: transcription failed: \(error.localizedDescription, privacy: .public)")
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
        let duration = (try? await AVURLAsset(url: url).load(.duration))
            .map(CMTimeGetSeconds) ?? 0
        let span = TranscribedSpan(text: text, start: 0, end: duration, confidence: nil)
        return RawTranscript(spans: [span], language: "")
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let created = AsrManager(config: .default, models: models)
            manager = created
            AppLog.transcription.atNotice.notice("fluidAudio: multilingual ASR models loaded")
            return created
        } catch {
            AppLog.transcription.atError.error("fluidAudio: model load failed: \(error.localizedDescription, privacy: .public)")
            throw AppError.modelDownloadFailed(error.localizedDescription)
        }
    }
}

#else

/// Built without the FluidAudio package linked: the multilingual on-device engine
/// is unavailable, so callers fall back to `OnDeviceTranscriber` (Apple Speech).
actor FluidAudioTranscriber {
    func transcribe(url: URL, language: MeetingLanguage) async throws -> RawTranscript {
        throw AppError.transcriptionFailed(
            NSLocalizedString("settings.fluid_audio.package_missing", comment: "FluidAudio package missing")
        )
    }
}

#endif
