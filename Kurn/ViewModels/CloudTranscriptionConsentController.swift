//
//  CloudTranscriptionConsentController.swift
//  Kurn
//

import Foundation
import KurnCore
import Observation

@MainActor
@Observable
final class CloudTranscriptionConsentController {
    /// What the pending "we will upload your audio" dialog is asking consent
    /// for. Not every cloud transcription engine has a configured `AIProvider`
    /// — ElevenLabs Scribe is a single-vendor `TranscriptionEngine`, so it
    /// gets its own case rather than being forced into a `providers` lookup.
    private enum ConsentSubject: Equatable {
        case provider(AIProvider)
        case elevenLabsScribe
    }

    var isPresented = false
    private var pendingSubject: ConsentSubject?
    /// The engine to select once consent is granted, or `nil` when the
    /// pending dialog is only about switching the Whisper *provider* (the
    /// engine is already `.whisperAPI` and stays that way).
    private var pendingEngine: TranscriptionEngine?

    func selectEngine(
        _ engine: TranscriptionEngine,
        settings: AppSettings,
        providers: [AIProvider],
        downloads: ModelDownloadController
    ) {
        switch engine {
        case .whisperAPI:
            guard let provider = providers.first(where: {
                $0.id == settings.transcriptionProviderID
            }) ?? providers.first else { return }
            guard settings.hasCloudTranscriptionConsent(for: provider) else {
                requestConsent(for: .provider(provider), selectingEngine: engine)
                return
            }
        case .elevenLabsScribe:
            guard settings.hasCloudTranscriptionConsent(forKey: AppSettings.elevenLabsScribeConsentKey) else {
                requestConsent(for: .elevenLabsScribe, selectingEngine: engine)
                return
            }
        case .appleSpeech, .fluidAudioParakeet, .whisperCpp:
            break
        }
        downloads.selectTranscriptionEngine(
            engine,
            settings: settings,
            transcriptionProviders: providers
        )
    }

    func selectProvider(
        _ providerID: String,
        settings: AppSettings,
        providers: [AIProvider]
    ) {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        guard settings.hasCloudTranscriptionConsent(for: provider) else {
            requestConsent(for: .provider(provider), selectingEngine: nil)
            return
        }
        settings.transcriptionProviderID = providerID
    }

    func presentIfNeeded(settings: AppSettings) {
        if settings.transcriptionEngine == .whisperAPI {
            let provider = settings.transcriptionProvider
            guard provider.isUsable else { return }
            if !settings.hasCloudTranscriptionConsent(for: provider) {
                requestConsent(for: .provider(provider), selectingEngine: .whisperAPI)
            }
        } else if settings.transcriptionEngine == .elevenLabsScribe,
                  !settings.hasCloudTranscriptionConsent(forKey: AppSettings.elevenLabsScribeConsentKey) {
            requestConsent(for: .elevenLabsScribe, selectingEngine: .elevenLabsScribe)
        }
    }

    func message(settings: AppSettings, providers: [AIProvider]) -> String {
        let displayName: String
        let destination: String
        switch pendingSubject {
        case .provider(let subjectProvider):
            displayName = subjectProvider.displayName
            destination = URLComponents(string: subjectProvider.baseURLString)?.host ?? subjectProvider.displayName
        case .elevenLabsScribe:
            displayName = "ElevenLabs"
            destination = "api.elevenlabs.io"
        case nil:
            let provider = settings.transcriptionProvider
            displayName = provider.displayName
            destination = URLComponents(string: provider.baseURLString)?.host ?? provider.displayName
        }
        let hourlySize = ByteCountFormatter.string(
            fromByteCount: settings.audioQuality.approximateBytesPerHour,
            countStyle: .file
        )
        return String(
            format: NSLocalizedString("settings.cloud_upload.message", comment: "Cloud upload disclosure"),
            displayName,
            destination,
            hourlySize
        )
    }

    func confirm(
        settings: AppSettings,
        providers: [AIProvider],
        downloads: ModelDownloadController
    ) {
        guard let pendingSubject else {
            cancel()
            return
        }
        let engineToSelect = pendingEngine
        switch pendingSubject {
        case .provider(let provider):
            settings.recordCloudTranscriptionConsent(for: provider)
            settings.transcriptionProviderID = provider.id
        case .elevenLabsScribe:
            settings.recordCloudTranscriptionConsent(forKey: AppSettings.elevenLabsScribeConsentKey)
        }
        cancel()
        if let engineToSelect {
            downloads.selectTranscriptionEngine(
                engineToSelect,
                settings: settings,
                transcriptionProviders: providers
            )
        }
    }

    func cancel() {
        isPresented = false
        pendingSubject = nil
        pendingEngine = nil
    }

    private func requestConsent(for subject: ConsentSubject, selectingEngine engine: TranscriptionEngine?) {
        pendingSubject = subject
        pendingEngine = engine
        isPresented = true
    }
}
