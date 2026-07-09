//
//  TranscriptionLanguageSupport.swift
//  Kurn
//
//  Whether a `MeetingLanguage` is expected to work with a given
//  `TranscriptionEngine`, so language pickers can warn up front instead of
//  the user only finding out via a transcription-time error.
//

import Speech

enum TranscriptionLanguageSupport {

    /// `.autoDetect` is always considered supported (every engine has some
    /// notion of auto-detection or ignores the hint entirely).
    static func isSupported(_ language: MeetingLanguage, by engine: TranscriptionEngine) -> Bool {
        guard let code = language.whisperCode else { return true }
        switch engine {
        case .whisperAPI:
            // Whisper's cloud API is the source of our language table.
            return true
        case .fluidAudioParakeet:
            return fluidAudioCodes.contains(code)
        case .appleSpeech:
            return appleSpeechCodes.contains(code)
        }
    }

    /// Languages supported by FluidAudio's on-device multilingual Parakeet
    /// TDT v3 model ("25 European languages" per FluidAudio's docs; codes
    /// sourced from the underlying nvidia/parakeet-tdt-0.6b-v3 model card).
    /// Revisit if FluidAudio changes the bundled batch ASR model.
    private static let fluidAudioCodes: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "pl", "cs", "sk", "hu", "ro",
        "bg", "hr", "sl", "da", "sv", "fi", "et", "lv", "lt", "el", "mt", "ru", "uk"
    ]

    /// Locales Apple's on-device speech recognizer actually ships, queried
    /// live rather than hardcoded since it varies by iOS version/device.
    private static let appleSpeechCodes: Set<String> = {
        Set(SFSpeechRecognizer.supportedLocales().map { String($0.identifier.prefix(2)) })
    }()
}
