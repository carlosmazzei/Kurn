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
    var isPresented = false
    private var pendingProviderID: String?
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
        if engine == .whisperAPI {
            guard let provider = providers.first(where: {
                $0.id == settings.transcriptionProviderID
            }) ?? providers.first else { return }
            guard settings.hasCloudTranscriptionConsent(for: provider) else {
                requestConsent(for: provider, selectingEngine: engine)
                return
            }
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
            requestConsent(for: provider, selectingEngine: nil)
            return
        }
        settings.transcriptionProviderID = providerID
    }

    func presentIfNeeded(settings: AppSettings) {
        let provider = settings.transcriptionProvider
        guard provider.isUsable else { return }
        if settings.transcriptionEngine == .whisperAPI,
           !settings.hasCloudTranscriptionConsent(for: provider) {
            requestConsent(for: provider, selectingEngine: .whisperAPI)
        }
    }

    func message(settings: AppSettings, providers: [AIProvider]) -> String {
        let provider = providers.first { $0.id == pendingProviderID }
            ?? settings.transcriptionProvider
        let destination = URLComponents(string: provider.baseURLString)?.host ?? provider.displayName
        let hourlySize = ByteCountFormatter.string(
            fromByteCount: settings.audioQuality.approximateBytesPerHour,
            countStyle: .file
        )
        return String(
            format: NSLocalizedString("settings.cloud_upload.message", comment: "Cloud upload disclosure"),
            provider.displayName,
            destination,
            hourlySize
        )
    }

    func confirm(
        settings: AppSettings,
        providers: [AIProvider],
        downloads: ModelDownloadController
    ) {
        guard let provider = providers.first(where: { $0.id == pendingProviderID }) else {
            cancel()
            return
        }
        let engineToSelect = pendingEngine
        settings.recordCloudTranscriptionConsent(for: provider)
        settings.transcriptionProviderID = provider.id
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
        pendingProviderID = nil
        pendingEngine = nil
    }

    private func requestConsent(for provider: AIProvider, selectingEngine engine: TranscriptionEngine?) {
        pendingProviderID = provider.id
        pendingEngine = engine
        isPresented = true
    }
}
