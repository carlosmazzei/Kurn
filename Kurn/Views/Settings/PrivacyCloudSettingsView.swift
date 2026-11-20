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
    @State private var pendingRevocation: String?

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
        .confirmationDialog(
            PrivacyCloudCopy.text("revoke_title"),
            isPresented: Binding(get: { pendingRevocation != nil }, set: { if !$0 { pendingRevocation = nil } }),
            titleVisibility: .visible
        ) {
            Button(PrivacyCloudCopy.text("revoke_automatic"), role: .destructive) {
                if let pendingRevocation { settings.revokeAutomaticCloudConsent(pendingRevocation) }
                pendingRevocation = nil
            }
        } message: {
            Text(PrivacyCloudCopy.text("revoke_detail"))
        }
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
                    pendingRevocation = destination
                }
                .accessibilityIdentifier("privacy.cloud.revoke")
            }
        } header: {
            Text(provider?.displayName ?? PrivacyCloudCopy.text("removed_provider"))
        } footer: {
            Text(PrivacyCloudCopy.host(of: destination))
        }
    }
}

enum PrivacyCloudCopy {
    static func text(_ key: String) -> String {
        NSLocalizedString("privacy.cloud." + key, comment: "Privacy and cloud settings")
    }

    static func state(_ allowed: Bool) -> String { text(allowed ? "allowed" : "not_allowed") }

    static func host(of destination: String) -> String {
        let endpoint = destination.split(separator: "|", maxSplits: 1).last.map(String.init) ?? destination
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
