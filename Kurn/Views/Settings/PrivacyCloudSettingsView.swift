//
//  PrivacyCloudSettingsView.swift
//  Kurn
//
//  One place to view and edit what may leave the device (CLAUDE.md, "Cloud
//  consent") and how recordings are protected on device: each cloud provider
//  with interactive toggles for on-request, automatic, and audio-upload
//  grants, the features currently using it, device lock/Lock Screen privacy,
//  and non-provider sharing (template sync and on-device diagnostic reports).
//

import KurnCore
import SwiftUI

struct PrivacyCloudSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var pendingRevocation: Revocation?
    @State private var showingDiagnosticReportsConsent = false
    @State private var authError: AppError?
    private let authorizer = SensitiveActionAuthorizer()

    private struct Revocation: Equatable {
        let destination: String
        let everything: Bool
        var includeAudio = true
    }

    var body: some View {
        Form {
            Section {
                Text(PrivacyCloudCopy.text("rule"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            let destinations = settings.editableCloudConsentDestinations
            if destinations.isEmpty {
                Section { Text(PrivacyCloudCopy.text("none")) }
            }
            ForEach(destinations, id: \.self) { destination in
                providerSection(destination)
            }
            devicePrivacySection
            otherSharingSection
        }
        .accessibilityIdentifier("settings.privacy_cloud.form")
        .navigationTitle(PrivacyCloudCopy.text("title"))
        .errorAlert($authError)
        .kurnDialog(
            isPresented: Binding(get: { pendingRevocation != nil }, set: { if !$0 { pendingRevocation = nil } }),
            iconSystemName: "icloud.slash",
            iconTint: Theme.warning,
            title: PrivacyCloudCopy.text(revocationTitleKey),
            message: PrivacyCloudCopy.text(revocationMessageKey),
            primaryTitle: PrivacyCloudCopy.text(pendingRevocation?.everything == true ? "revoke_all" : "revoke_automatic"),
            primaryRole: .destructive,
            primaryAction: {
                guard let pendingRevocation else { return }
                if pendingRevocation.everything {
                    settings.revokeAllCloudConsent(pendingRevocation.destination)
                } else {
                    settings.revokeAutomaticCloudConsent(
                        pendingRevocation.destination,
                        includeAudio: pendingRevocation.includeAudio
                    )
                }
                self.pendingRevocation = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: $showingDiagnosticReportsConsent,
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: Theme.info,
            title: NSLocalizedString("settings.diagnostic_reports.consent_title", comment: "Enable diagnostic reports"),
            message: NSLocalizedString("settings.diagnostic_reports.consent_message", comment: "Explains on-device diagnostic reports"),
            primaryTitle: NSLocalizedString("settings.diagnostic_reports.enable", comment: "Enable"),
            primaryAction: { settings.diagnosticReportsConsented = true },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    /// The bulk "Stop automatic sending" button also withdraws audio upload;
    /// the Automatic toggle leaves it alone, so both the title and message
    /// distinguish text-only revocation from bulk revocation.
    private var revocationTitleKey: String {
        guard let pendingRevocation else { return "revoke_title" }
        if pendingRevocation.everything { return "revoke_all_title" }
        return pendingRevocation.includeAudio ? "revoke_title" : "revoke_text_title"
    }

    private var revocationMessageKey: String {
        guard let pendingRevocation else { return "revoke_detail" }
        if pendingRevocation.everything { return "revoke_all_detail" }
        return pendingRevocation.includeAudio ? "revoke_detail" : "revoke_text_detail"
    }

    private func providerSection(_ destination: String) -> some View {
        let provider = settings.provider(forCloudConsent: destination)
        let ledger = settings.cloudConsents
        let onRequest = ledger.allows(destination, for: .onRequest)
        let automatic = ledger.allows(destination, for: .automatic)
        // By destination, so an old endpoint's consent stays visible and revocable.
        let audio = settings.hasCloudTranscriptionConsent(destination: destination)
        return Section {
            Toggle(
                PrivacyCloudCopy.text("on_request"),
                isOn: Binding(
                    get: { onRequest },
                    set: { enabled in setOnRequest(enabled, destination: destination, provider: provider) }
                )
            )
            .disabled(provider == nil && !onRequest)
            .accessibilityIdentifier("privacy.cloud.onRequest")

            Toggle(
                PrivacyCloudCopy.text("automatic"),
                isOn: Binding(
                    get: { automatic },
                    set: { enabled in setAutomatic(enabled, destination: destination, provider: provider) }
                )
            )
            .disabled(provider == nil && !automatic)
            .accessibilityIdentifier("privacy.cloud.automatic")

            if (provider?.supportsTranscription ?? false) || audio {
                Toggle(
                    PrivacyCloudCopy.text("audio"),
                    isOn: Binding(
                        get: { audio },
                        set: { enabled in setAudioUpload(enabled, destination: destination, provider: provider) }
                    )
                )
                .disabled((provider?.supportsTranscription != true) && !audio)
                .accessibilityIdentifier("privacy.cloud.audio")
            }

            if let provider {
                let features = PrivacyCloudCopy.features(using: provider, settings: settings)
                if !features.isEmpty {
                    LabeledContent(PrivacyCloudCopy.text("features"), value: features.joined(separator: ", "))
                }
            }
            if automatic || audio {
                Button(PrivacyCloudCopy.text("revoke_automatic"), role: .destructive) {
                    pendingRevocation = Revocation(destination: destination, everything: false)
                }
                .accessibilityIdentifier("privacy.cloud.revoke")
            }
            if onRequest || automatic || audio || provider?.id == settings.readAloud.providerID {
                Button(PrivacyCloudCopy.text("revoke_all"), role: .destructive) {
                    pendingRevocation = Revocation(destination: destination, everything: true)
                }
                .accessibilityIdentifier("privacy.cloud.revokeAll")
            }
        } header: {
            Text(provider?.displayName ?? PrivacyCloudCopy.text("removed_provider"))
        } footer: {
            Text(verbatim: PrivacyCloudCopy.endpoint(of: destination))
        }
    }

    private var devicePrivacySection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { settings.requireAuthForRecordings },
                    set: { setRequireAuth($0) }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.require_auth_for_recordings", comment: "Require authentication for recordings"),
                    detail: NSLocalizedString("settings.require_auth_for_recordings_footer", comment: "Explains authentication and at-rest encryption")
                )
            }
            .accessibilityIdentifier("privacy.cloud.requireAuth")

            Toggle(
                isOn: Binding(
                    get: { settings.hideLiveActivityMeetingTitle },
                    set: { settings.hideLiveActivityMeetingTitle = $0 }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.hide_live_activity_meeting_title", comment: "Hide meeting title on Lock Screen"),
                    detail: NSLocalizedString("settings.hide_live_activity_meeting_title_footer", comment: "Explains Live Activity title redaction")
                )
            }
            .accessibilityIdentifier("privacy.cloud.hideLiveActivityTitle")
        } header: {
            Text(NSLocalizedString("settings.recording_section_privacy", comment: "Privacy"))
        } footer: {
            Text(NSLocalizedString("settings.recording_section_privacy_footer", comment: "Explains audio is always encrypted regardless of these toggles"))
        }
    }

    private var otherSharingSection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { settings.templatesSyncEnabled },
                    set: { setTemplatesSync($0) }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.templates_sync", comment: "Sync Templates via iCloud"),
                    detail: NSLocalizedString("settings.templates_sync_footer", comment: "Templates sync footer")
                )
            }
            .accessibilityIdentifier("privacy.cloud.templatesSync")

            Toggle(
                isOn: Binding(
                    get: { settings.diagnosticReportsConsented },
                    set: { enabled in
                        if enabled {
                            showingDiagnosticReportsConsent = true
                        } else {
                            settings.diagnosticReportsConsented = false
                        }
                    }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.diagnostic_reports", comment: "Diagnostic Reports"),
                    detail: NSLocalizedString("settings.diagnostic_reports_footer", comment: "Explains diagnostic reports")
                )
            }
            .accessibilityIdentifier("privacy.cloud.diagnosticReports")
        } header: {
            Text(PrivacyCloudCopy.text("other"))
        } footer: {
            Text(PrivacyCloudCopy.text("downloads"))
        }
    }

    private func setOnRequest(_ enabled: Bool, destination: String, provider: AIProvider?) {
        if enabled {
            guard let provider else { return }
            authorizeCloudChange {
                settings.grantCloudConsent(provider, for: .onRequest)
            }
        } else {
            pendingRevocation = Revocation(destination: destination, everything: true)
        }
    }

    private func setAutomatic(_ enabled: Bool, destination: String, provider: AIProvider?) {
        if enabled {
            guard let provider else { return }
            authorizeCloudChange {
                settings.grantCloudConsent(provider, for: .onRequest)
                settings.grantCloudConsent(provider, for: .automatic)
            }
        } else {
            pendingRevocation = Revocation(destination: destination, everything: false, includeAudio: false)
        }
    }

    private func setTemplatesSync(_ enabled: Bool) {
        if enabled {
            authorizeCloudChange {
                settings.templatesSyncEnabled = true
            }
        } else {
            settings.templatesSyncEnabled = false
        }
    }

    private func setAudioUpload(_ enabled: Bool, destination: String, provider: AIProvider?) {
        if enabled {
            guard let provider, provider.supportsTranscription else { return }
            authorizeCloudChange {
                settings.recordCloudTranscriptionConsent(for: provider)
            }
        } else {
            settings.revokeCloudTranscriptionConsent(destination)
        }
    }

    private func authorizeCloudChange(_ action: @escaping @MainActor () -> Void) {
        let requireAuth = settings.requireAuthForRecordings
        Task { @MainActor in
            await authorizer.perform(
                requireAuth: requireAuth,
                onDenied: { authError = $0 },
                action
            )
        }
    }

    private func setRequireAuth(_ newValue: Bool) {
        let current = settings.requireAuthForRecordings
        Task { @MainActor in
            switch await authorizer.authorizeRequireAuthChange(to: newValue, currentlyRequired: current) {
            case .authorized: settings.requireAuthForRecordings = newValue
            case .cancelled: break
            case .denied(let error): authError = error
            }
        }
    }
}

enum PrivacyCloudCopy {
    static func text(_ key: String) -> String {
        NSLocalizedString("privacy.cloud." + key, comment: "Privacy and cloud settings")
    }

    static func state(_ allowed: Bool) -> String { text(allowed ? "allowed" : "not_allowed") }

    /// The full endpoint (scheme, host, port and path), since any of them
    /// distinguishes one grant from another.
    static func endpoint(of destination: String) -> String {
        destination.split(separator: "|", maxSplits: 1).last.map(String.init) ?? destination
    }

    static func host(of destination: String) -> String {
        let endpoint = endpoint(of: destination)
        return URLComponents(string: endpoint)?.host ?? endpoint
    }

    /// The automatic features currently sending to this provider.
    @MainActor
    static func features(using provider: AIProvider, settings: AppSettings) -> [String] {
        var names: [String] = []
        if settings.transcriptionEngine == .whisperAPI, settings.transcriptionProvider.id == provider.id {
            names.append(text("feature.transcription"))
        }
        if settings.aiProvider.id == provider.id {
            if settings.aiTitleCloudEnabled { names.append(text("feature.title")) }
            if settings.wikiEnabled { names.append(text("feature.wiki")) }
            if settings.correctionEnabled { names.append(text("feature.correction")) }
        }
        if settings.knowledgeEnabled, settings.knowledgeProvider?.id == provider.id {
            names.append(text("feature.knowledge"))
        }
        return names
    }
}
