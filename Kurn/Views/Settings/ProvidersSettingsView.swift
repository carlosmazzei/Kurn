//
//  ProvidersSettingsView.swift
//  Kurn
//
//  The cloud AI providers and their API keys. Keys themselves never live in
//  `AppSettings` — they're in the Keychain, keyed by `AIProvider.keychainAccount`;
//  this screen only edits the non-secret config around them.
//

import KurnCore
import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var showingAddProvider = false
    @State private var keychainError: AppError?

    var body: some View {
        Form {
            Section {
                ForEach(settings.providers) { provider in
                    NavigationLink {
                        ProviderEditor(
                            provider: provider,
                            onSave: { updated in
                                settings.updateProvider(updated)
                                // Any edit here (key, base URL, kind) could be
                                // exactly what fixes a configuration failure
                                // that tripped the provider circuit breaker,
                                // so give automatic wiki/AI-title generation
                                // another chance instead of leaving them
                                // blocked forever waiting for an explicit
                                // retry that title generation never sends.
                                Task { await ProviderCircuitBreaker.shared.reset(providerID: updated.id) }
                            },
                            onDelete: { settings.removeProvider(provider) }
                        )
                    } label: {
                        ProviderRow(provider: provider)
                    }
                    .accessibilityIdentifier("settings.providers.row.\(provider.id)")
                }
            } header: {
                Text(NSLocalizedString("settings.providers", comment: "AI Providers"))
            } footer: {
                Text(NSLocalizedString("settings.providers.keychain_footer", comment: "Keys stay in the device Keychain"))
            }
        }
        .accessibilityIdentifier("settings.providers.form")
        .navigationTitle(NSLocalizedString("settings.providers", comment: "AI Providers"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddProvider = true
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel(NSLocalizedString("settings.add_provider", comment: "Add Provider"))
                }
                .accessibilityIdentifier("settings.providers.add")
            }
        }
        .errorAlert($keychainError, offersRecovery: false)
        .sheet(isPresented: $showingAddProvider) {
            NavigationStack {
                AddProviderView { provider, key in
                    // The provider config itself is added either way — a
                    // Keychain failure here means "added without a key yet",
                    // not "add failed", and is surfaced rather than silently
                    // leaving the row looking unconfigured with no explanation
                    // (H7 PR 14).
                    settings.addProvider(provider)
                    if key.isEmpty {
                        settings.credentials.invalidate()
                    } else if case .failed(let reason) = settings.credentials.saveKey(key, for: provider) {
                        keychainError = .keychainAccessFailed(reason.rawValue)
                    }
                    showingAddProvider = false
                }
            }
            .environment(settings)
        }
    }
}
