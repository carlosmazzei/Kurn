//
//  PrivacyCloudSettingsView.swift
//  Kurn
//
//  One place that lists what may leave the device (CLAUDE.md, "Cloud
//  consent"): each cloud provider with its on-request and automatic grants and
//  the features using it, then the sharing that is not an AI provider.
//

import KurnCore
import SwiftUI

struct PrivacyCloudSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var pendingRevocation: Revocation?

    private struct Revocation: Equatable {
        let destination: String
        let everything: Bool
    }

    var body: some View {
        Form {
            Section {
                Text(PrivacyCloudCopy.text("rule"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if settings.cloudConsents.destinations.isEmpty {
                Section { Text(PrivacyCloudCopy.text("none")) }
            }
            ForEach(settings.cloudConsents.destinations, id: \.self) { destination in
                providerSection(destination)
            }
            Section {
                LabeledContent(
                    NSLocalizedString("settings.templates_sync", comment: "Sync Templates via iCloud"),
                    value: PrivacyCloudCopy.state(settings.templatesSyncEnabled)
                )
                LabeledContent(
                    NSLocalizedString("settings.diagnostic_reports", comment: "Diagnostic Reports"),
                    value: PrivacyCloudCopy.state(settings.diagnosticReportsConsented)
                )
            } header: {
                Text(PrivacyCloudCopy.text("other"))
            } footer: {
                Text(PrivacyCloudCopy.text("downloads"))
            }
        }
        .navigationTitle(PrivacyCloudCopy.text("title"))
        .kurnDialog(
            isPresented: Binding(get: { pendingRevocation != nil }, set: { if !$0 { pendingRevocation = nil } }),
            iconSystemName: "icloud.slash",
            iconTint: Theme.warning,
            title: PrivacyCloudCopy.text(pendingRevocation?.everything == true ? "revoke_all_title" : "revoke_title"),
            message: PrivacyCloudCopy.text(pendingRevocation?.everything == true ? "revoke_all_detail" : "revoke_detail"),
            primaryTitle: PrivacyCloudCopy.text(pendingRevocation?.everything == true ? "revoke_all" : "revoke_automatic"),
            primaryRole: .destructive,
            primaryAction: {
                guard let pendingRevocation else { return }
                if pendingRevocation.everything {
                    settings.revokeAllCloudConsent(pendingRevocation.destination)
                } else {
                    settings.revokeAutomaticCloudConsent(pendingRevocation.destination)
                }
                self.pendingRevocation = nil
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    private func providerSection(_ destination: String) -> some View {
        let provider = settings.provider(forCloudConsent: destination)
        let ledger = settings.cloudConsents
        let automatic = ledger.allows(destination, for: .automatic)
        return Section {
            LabeledContent(PrivacyCloudCopy.text("on_request"),
                           value: PrivacyCloudCopy.state(ledger.allows(destination, for: .onRequest)))
            LabeledContent(PrivacyCloudCopy.text("automatic"), value: PrivacyCloudCopy.state(automatic))
            if let provider {
                let features = PrivacyCloudCopy.features(using: provider, settings: settings)
                if !features.isEmpty {
                    LabeledContent(PrivacyCloudCopy.text("features"), value: features.joined(separator: ", "))
                }
            }
            if automatic {
                Button(PrivacyCloudCopy.text("revoke_automatic"), role: .destructive) {
                    pendingRevocation = Revocation(destination: destination, everything: false)
                }
                .accessibilityIdentifier("privacy.cloud.revoke")
            }
            Button(PrivacyCloudCopy.text("revoke_all"), role: .destructive) {
                pendingRevocation = Revocation(destination: destination, everything: true)
            }
            .accessibilityIdentifier("privacy.cloud.revokeAll")
        } header: {
            Text(provider?.displayName ?? PrivacyCloudCopy.text("removed_provider"))
        } footer: {
            Text(verbatim: PrivacyCloudCopy.endpoint(of: destination))
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
