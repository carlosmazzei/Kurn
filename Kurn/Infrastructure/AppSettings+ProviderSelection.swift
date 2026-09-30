//
//  AppSettings+ProviderSelection.swift
//  Kurn
//
//  Which providers are usable right now, and the invariant that keeps the
//  selected summary and transcription providers pointing at one of them.
//
//  Both used to live in a Settings view extension and ran only when the
//  Settings root appeared or its `keyRevision` counter changed, so a key
//  removed anywhere else left a selection pointing at a provider without one.
//  They now run after every write through `credentials`, wherever it happens.
//

import Foundation
import KurnCore

extension AppSettings {

    /// Providers usable right now: a key in the Keychain for a cloud vendor,
    /// or a runnable `SystemLanguageModel` for the on-device provider (which
    /// has no key at all). Reading it registers a view with `credentials`, so
    /// the list re-derives after a key is added or removed.
    var configuredProviders: [AIProvider] {
        providers.filter { credentials.isUsable($0) }
    }

    /// Configured providers that can run cloud (Whisper) transcription — the
    /// candidate list for the transcription-provider picker.
    var configuredTranscriptionProviders: [AIProvider] {
        configuredProviders.filter(\.supportsTranscription)
    }

    /// Configured providers that can generate summaries/chat replies — the
    /// candidate list for the summary-provider picker. Narrower than
    /// `configuredProviders`: a transcription-only provider (ElevenLabs) is
    /// usable but must never be offered as a summary provider.
    var configuredSummaryProviders: [AIProvider] {
        configuredProviders.filter(\.supportsSummarization)
    }

    /// Repoints a selection whose provider is no longer usable. The summary
    /// selection moves to the first usable summary provider (and stays put
    /// when there is none, so the picker can say so). Cloud transcription
    /// moves to the first usable transcription provider, or falls back to the
    /// on-device engine when none has a key.
    func ensureProviderSelectionsAreUsable() {
        let summaryProviders = configuredSummaryProviders
        if !summaryProviders.isEmpty, !summaryProviders.contains(where: { $0.id == aiProviderID }) {
            aiProviderID = summaryProviders[0].id
        }

        guard transcriptionEngine == .whisperAPI else { return }
        let transcriptionProviders = configuredTranscriptionProviders
        if transcriptionProviders.isEmpty {
            transcriptionEngine = .appleSpeech
        } else if !transcriptionProviders.contains(where: { $0.id == transcriptionProviderID }) {
            transcriptionProviderID = transcriptionProviders[0].id
        }
    }
}
