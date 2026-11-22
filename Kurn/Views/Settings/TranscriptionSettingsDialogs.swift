//
//  TranscriptionSettingsDialogs.swift
//  Kurn
//
//  `TranscriptionSettingsView`'s provider-key alert and cloud-upload
//  consent `kurnDialog`, parameterized like `recordingDeleteDialog` —
//  the body's modifier chain is long enough that these inline closures
//  tip the type-checker over CI's slower compiler.
//

import SwiftUI

extension View {
    func presetMissingKeyAlert(provider: Binding<AIProvider?>) -> some View {
        alert(
            NSLocalizedString("settings.preset.needs_key.title", comment: "Preset provider key missing"),
            isPresented: Binding(
                get: { provider.wrappedValue != nil },
                set: { if !$0 { provider.wrappedValue = nil } }
            ),
            presenting: provider.wrappedValue
        ) { _ in
            Button(NSLocalizedString("common.ok", comment: "OK")) { provider.wrappedValue = nil }
        } message: { provider in
            Text(String(
                format: NSLocalizedString("settings.preset.needs_key", comment: "Preset provider key missing"),
                provider.displayName
            ))
        }
    }

    func cloudUploadConsentDialog(
        consent: CloudTranscriptionConsentController,
        settings: AppSettings,
        providers: [AIProvider],
        downloads: ModelDownloadController
    ) -> some View {
        kurnDialog(
            isPresented: Binding(
                get: { consent.isPresented },
                set: { consent.isPresented = $0 }
            ),
            iconSystemName: "icloud.and.arrow.up.fill",
            iconTint: Theme.info,
            title: NSLocalizedString("settings.cloud_upload.title", comment: "Cloud audio upload"),
            message: consent.message(settings: settings, providers: providers),
            primaryTitle: NSLocalizedString("settings.cloud_upload.allow", comment: "Allow cloud upload"),
            primaryAction: {
                consent.confirm(
                    settings: settings,
                    providers: providers,
                    downloads: downloads
                )
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: { consent.cancel() }
        )
    }
}
