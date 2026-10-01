//
//  AppSettings+Migration.swift
//  Kurn
//
//  How stored values from older versions are carried forward at launch:
//  the legacy transcription mode becomes an explicit engine, and stored
//  providers are merged with the current built-in list.
//

import Foundation
import KurnCore

extension AppSettings {

    /// Derive the initial `TranscriptionEngine` from the legacy `defaultMode` +
    /// on-device-multilingual consent so upgrading users keep their behavior.
    nonisolated static func migratedTranscriptionEngine(
        mode: TranscriptionMode,
        language: MeetingLanguage,
        multilingualConsented: Bool
    ) -> TranscriptionEngine {
        switch mode {
        case .whisperAPI:
            return .whisperAPI
        case .onDevice:
            // The old "Auto + multilingual model consented" path routed to
            // FluidAudio Parakeet; everything else used Apple Speech.
            return (language == .autoDetect && multilingualConsented) ? .fluidAudioParakeet : .appleSpeech
        }
    }

    static func mergedProviders(_ stored: [AIProvider]) -> [AIProvider] {
        var providers = AIProvider.defaultProviders
        for provider in stored where !provider.isBuiltIn && !providers.contains(where: { $0.id == provider.id }) {
            providers.append(provider)
        }
        return providers
    }
}
