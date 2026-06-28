//
//  LanguageDetectors.swift
//  Kurn
//
//  Language-detection engines for the recognition pipeline. Detection only
//  matters for engines that need a pinned locale (Apple Speech) — FluidAudio
//  Parakeet and Whisper detect the language themselves, so the default engine
//  is a no-op that defers to them.
//

import Foundation
import NaturalLanguage

/// Defers detection to the transcription engine (current behavior): returns the
/// caller's hint unchanged.
struct NoOpLanguageDetector: LanguageDetecting {
    func detect(url: URL, hint: MeetingLanguage) async -> MeetingLanguage { hint }
}

/// Detects the spoken language on-device by running FluidAudio's multilingual
/// ASR and classifying the recognized text with Apple's `NLLanguageRecognizer`.
/// Lets even Apple Speech transcribe an "Auto" meeting in the right locale.
/// When the language is already pinned, or detection fails, it returns the hint
/// unchanged so transcription never blocks on it.
actor FluidAudioLanguageDetector: LanguageDetecting {

    private let transcriber = FluidAudioTranscriber()

    /// Seconds of audio fed to detection. The language is obvious from a short
    /// sample, so transcribing only a prefix avoids a second full-length ASR pass
    /// (and its memory) just to classify the language.
    private static let prefixSeconds: TimeInterval = 60

    func detect(url: URL, hint: MeetingLanguage) async -> MeetingLanguage {
        // A pinned language needs no detection.
        guard hint == .autoDetect else { return hint }

        // Detect on a short prefix; fall back to the whole file if trimming fails
        // or the clip is already shorter than the prefix.
        let prefixURL = (try? VADAudioCompactor.prefixClip(url: url, seconds: Self.prefixSeconds)) ?? nil
        let target = prefixURL ?? url
        defer {
            if let prefixURL { try? FileManager.default.removeItem(at: prefixURL) }
        }

        do {
            let raw = try await transcriber.transcribe(url: target, language: .autoDetect)
            let text = raw.spans.map { $0.text }.joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return hint }

            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            guard let code = recognizer.dominantLanguage?.rawValue else { return hint }

            let detected = MeetingLanguage(detectedCode: code)
            AppLog.transcription.atInfo.info("langDetect: fluidAudio LID -> \(code, privacy: .public) (\(detected.rawValue, privacy: .public))")
            return detected
        } catch {
            AppLog.transcription.atError.error("langDetect: fluidAudio LID failed: \(error.localizedDescription, privacy: .public)")
            return hint
        }
    }
}
