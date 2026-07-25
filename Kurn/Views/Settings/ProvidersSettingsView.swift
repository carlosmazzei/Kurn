//
//  ProvidersSettingsView.swift
//  Kurn
//
//  The cloud AI providers and their API keys. Keys themselves never live in
//  `AppSettings` — they're in the Keychain, keyed by `AIProvider.keychainAccount`;
//  this screen only edits the non-secret config around them.
//

import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(AppSettings.self) private var settings

    /// Bumped whenever a key is added, changed or removed, so the rows re-read
    /// Keychain status. Owned by the Settings root, which also re-validates the
    /// selected providers when it changes.
    @Binding var keyRevision: Int

    @State private var showingAddProvider = false

    var body: some View {
        Form {
            Section(NSLocalizedString("settings.providers", comment: "AI Providers")) {
                ForEach(settings.providers) { provider in
                    NavigationLink {
                        ProviderEditor(
                            provider: provider,
                            onSave: { updated in
                                settings.updateProvider(updated)
                                keyRevision += 1
                            },
                            onDelete: {
                                settings.removeProvider(provider)
                                keyRevision += 1
                            },
                            onChange: { keyRevision += 1 }
                        )
                    } label: {
                        ProviderRow(provider: provider, revision: keyRevision)
                    }
                }
                Button {
                    showingAddProvider = true
                } label: {
                    Label(NSLocalizedString("settings.add_provider", comment: "Add Provider"), systemImage: "plus")
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.providers", comment: "AI Providers"))
        .sheet(isPresented: $showingAddProvider) {
            NavigationStack {
                AddProviderView { provider, key in
                    settings.addProvider(provider)
                    if !key.isEmpty {
                        KeychainManager.shared.set(key, for: provider.keychainAccount)
                    }
                    keyRevision += 1
                    showingAddProvider = false
                }
            }
        }
    }
}
