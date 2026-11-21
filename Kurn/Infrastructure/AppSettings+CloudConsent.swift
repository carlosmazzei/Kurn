import Foundation
import KurnCore

/// One ledger for every feature that sends content to a cloud provider
/// (CLAUDE.md, "Cloud consent"). Feature toggles still say which features run;
/// the ledger says which provider may receive content, and for what purpose.
extension AppSettings {
    static let cloudConsentsKey = "settings.cloudConsents.v1"

    var cloudConsents: CloudConsentLedger {
        access(keyPath: \.cloudConsents)
        guard let data = defaults.data(forKey: Self.cloudConsentsKey) else { return CloudConsentLedger() }
        return (try? CloudConsentLedger.decode(data)) ?? CloudConsentLedger()
    }

    func cloudConsentDestination(for provider: AIProvider) -> String {
        CloudConsentLedger.destination(providerID: provider.id, endpoint: provider.baseURLString)
    }

    /// The on-device provider never needs a grant: nothing leaves the device.
    func allowsCloud(_ provider: AIProvider, for purpose: CloudConsentPurpose) -> Bool {
        provider.kind == .appleOnDevice || cloudConsents.allows(cloudConsentDestination(for: provider), for: purpose)
    }

    func grantCloudConsent(_ provider: AIProvider, for purpose: CloudConsentPurpose, at date: Date = Date()) {
        guard provider.kind != .appleOnDevice else { return }
        var ledger = cloudConsents
        ledger.grant(cloudConsentDestination(for: provider), for: purpose, at: date)
        saveCloudConsents(ledger)
    }

    /// Withdrawing audio upload permission clears the destination's upload key
    /// and falls back to on-device transcription if Whisper API was using it.
    func revokeCloudTranscriptionConsent(_ destination: String) {
        removeCloudTranscriptionConsent(destination)
        // Fall back to on-device transcription rather than leave an engine
        // selected that can no longer upload.
        if transcriptionEngine == .whisperAPI, cloudConsentDestination(for: transcriptionProvider) == destination {
            transcriptionEngine = .appleSpeech
        }
    }

    /// Withdrawing automatic sending also turns off the per-recording features
    /// that were using this destination, so no toggle is left on without a grant.
    func revokeAutomaticCloudConsent(_ destination: String) {
        var ledger = cloudConsents
        ledger.revoke(destination, for: .automatic)
        saveCloudConsents(ledger)
        revokeCloudTranscriptionConsent(destination)
        if cloudConsentDestination(for: aiProvider) == destination {
            wikiEnabled = false
            correctionEnabled = false
            aiTitleCloudEnabled = false
        }
    }

    /// Withdrawing every grant also moves the summary and Knowledge providers
    /// that use this destination to on-device, since choosing a provider is
    /// what grants on-request use.
    func revokeAllCloudConsent(_ destination: String) {
        revokeAutomaticCloudConsent(destination)
        if cloudConsentDestination(for: aiProvider) == destination {
            aiProviderID = AIProvider.appleOnDevice.id
        }
        if let speech = providers.first(where: { $0.id == readAloud.providerID }),
           cloudConsentDestination(for: speech) == destination {
            readAloud.providerID = AIProvider.appleOnDevice.id
        }
        if var controls = knowledgeControls, let provider = knowledgeProvider,
           cloudConsentDestination(for: provider) == destination {
            controls.providerID = AIProvider.appleOnDevice.id
            try? saveKnowledgeControls(controls)
        }
        var ledger = cloudConsents
        ledger.revokeAll(destination)
        saveCloudConsents(ledger)
    }

    /// Every destination with a text grant or an audio upload consent, for Privacy & Cloud.
    var cloudConsentDestinationsForDisplay: [String] {
        Array(Set(cloudConsents.destinations).union(cloudTranscriptionConsentKeys)).sorted()
    }

    /// Every destination that can be managed in Privacy & Cloud: any configured
    /// cloud provider with a saved API key (or currently selected), plus any
    /// destination that already holds a text or audio upload consent.
    var editableCloudConsentDestinations: [String] {
        let configured = providers
            .filter { $0.kind != .appleOnDevice && (credentials.hasKey(for: $0) || $0.id == aiProviderID) }
            .map(cloudConsentDestination(for:))
        return Array(Set(configured).union(cloudConsentDestinationsForDisplay)).sorted()
    }

    /// The provider configured for a destination, if it still exists.
    func provider(forCloudConsent destination: String) -> AIProvider? {
        providers.first { cloudConsentDestination(for: $0) == destination }
    }

    /// Runs once, when no ledger is stored: every send the person already
    /// allowed becomes the matching grant, so upgrading asks nothing again.
    func migrateCloudConsentsIfNeeded(now: Date = Date()) {
        guard defaults.object(forKey: Self.cloudConsentsKey) == nil else { return }
        var ledger = CloudConsentLedger()
        let summary = aiProvider
        if summary.kind != .appleOnDevice, credentials.hasKey(for: summary) {
            let destination = cloudConsentDestination(for: summary)
            ledger.grant(destination, for: .onRequest, at: now)
            if wikiEnabled || correctionEnabled || aiTitleCloudEnabled {
                ledger.grant(destination, for: .automatic, at: now)
            }
        }
        saveCloudConsents(ledger)
    }

    private func saveCloudConsents(_ ledger: CloudConsentLedger) {
        guard let data = try? ledger.encoded() else { return }
        withMutation(keyPath: \.cloudConsents) { defaults.set(data, forKey: Self.cloudConsentsKey) }
    }
}
