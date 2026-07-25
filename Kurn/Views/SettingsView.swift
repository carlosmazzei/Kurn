//
//  SettingsView.swift
//  Kurn
//
//  The Settings hub. This screen used to be one flat `Form` with twelve stacked
//  sections — providers, the whole recognition pipeline, summaries, tags, search,
//  templates, recording, diagnostics, storage, models and about — which meant a
//  long undifferentiated scroll that mixed unrelated decisions.
//
//  It is now a short list of destinations grouped by subject, each pushing a
//  focused screen in `Views/Settings/`. What stays here is what has to: the
//  destructive reset, the shared key-revision counter, and the two invariants
//  that must run whatever the user drills into.
//

import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) var settings
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss

    /// Owns the FluidAudio download state shared by the Transcription, Recording
    /// and Storage screens — it has to outlive any one of them, so it's created
    /// here and injected into the environment.
    @State private var downloads = ModelDownloadController()

    /// Bumped after editing an API key so provider-dependent rows re-read
    /// Keychain status. Passed down rather than re-derived so one counter drives
    /// every screen.
    @State var keyRevision = 0

    @State var showingDeleteConfirm = false
    /// Set when "Delete all data" fails to erase the store, so the failure
    /// surfaces instead of the wipe silently doing nothing.
    @State var dataError: AppError?

    var body: some View {
        Form {
            Section {
                link(
                    NSLocalizedString("settings.providers", comment: "AI Providers"),
                    systemImage: "brain"
                ) {
                    ProvidersSettingsView(keyRevision: $keyRevision)
                }
                link(
                    NSLocalizedString("settings.summary", comment: "Summary"),
                    systemImage: "sparkles"
                ) {
                    SummarySettingsView(keyRevision: keyRevision)
                }
                link(
                    NSLocalizedString("settings.semantic_search_title", comment: "Search and chat"),
                    systemImage: "magnifyingglass"
                ) {
                    SemanticSearchSettingsView()
                }
                link(
                    NSLocalizedString("settings.wiki_title", comment: "Meeting wiki"),
                    systemImage: "book"
                ) {
                    WikiSettingsView(keyRevision: keyRevision)
                }
            } header: {
                Text(NSLocalizedString("settings.group.intelligence", comment: "Intelligence group"))
            }

            Section {
                link(
                    NSLocalizedString("settings.recording", comment: "Recording"),
                    systemImage: "mic"
                ) {
                    RecordingSettingsView()
                }
                link(
                    NSLocalizedString("settings.transcription", comment: "Transcription"),
                    systemImage: "waveform"
                ) {
                    TranscriptionSettingsView(keyRevision: keyRevision)
                }
            } header: {
                Text(NSLocalizedString("settings.group.capture", comment: "Capture group"))
            }

            Section {
                link(
                    NSLocalizedString("tag.title", comment: "Tags"),
                    systemImage: "tag"
                ) {
                    TagsSettingsView()
                }
                link(
                    NSLocalizedString("usage_insights.title", comment: "Usage Insights"),
                    systemImage: "chart.bar"
                ) {
                    UsageInsightsView()
                }
            } header: {
                Text(NSLocalizedString("settings.group.library", comment: "Library group"))
            } footer: {
                Text(NSLocalizedString("usage_insights.footer", comment: "Explains local-only usage data"))
            }

            Section {
                link(
                    NSLocalizedString("settings.storage", comment: "Storage"),
                    systemImage: "internaldrive"
                ) {
                    StorageSettingsView()
                }
                link(
                    NSLocalizedString("settings.diagnostics", comment: "Diagnostics"),
                    systemImage: "stethoscope"
                ) {
                    DiagnosticsSettingsView()
                }
                link(
                    NSLocalizedString("settings.about", comment: "About"),
                    systemImage: "info.circle"
                ) {
                    AboutSettingsView()
                }
            } header: {
                Text(NSLocalizedString("settings.group.system", comment: "System group"))
            }

            Section {
                Button(role: .destructive) { showingDeleteConfirm = true } label: {
                    Text(NSLocalizedString("settings.delete_all", comment: "Delete All Data"))
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.title", comment: "Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .environment(downloads)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
            }
        }
        // These two run here rather than on the Providers screen: a key can be
        // removed from any drill-down, and the selected summary/transcription
        // provider must never be left pointing at one without a key.
        .onAppear {
            ensureSelectedProviderIsConfigured()
            ensureWhisperSelectionIsAllowed()
        }
        .onChange(of: keyRevision) { _, _ in
            ensureSelectedProviderIsConfigured()
            ensureWhisperSelectionIsAllowed()
        }
        .kurnDialog(
            isPresented: $showingDeleteConfirm,
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.delete_all.confirm", comment: "Confirm delete all"),
            message: NSLocalizedString("settings.delete_all.message", comment: ""),
            primaryTitle: NSLocalizedString("settings.delete_all", comment: "Delete All Data"),
            primaryRole: .destructive,
            primaryAction: deleteAllData,
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .errorAlert($dataError)
    }

    /// One hub row: icon + title pushing a destination.
    ///
    /// The destination gets `downloads` injected here rather than relying on the
    /// `.environment(downloads)` applied to the hub's `Form`. This view is the
    /// root content of a `NavigationStack` (see `MeetingsListView`), so pushed
    /// destinations are hosted by the stack and don't reliably inherit an
    /// environment object installed inside the root — every other object the
    /// screens read (`AppSettings`, the coordinators) comes from `KurnApp`, above
    /// the stack, which is why only the three screens reading `downloads`
    /// (Recording, Transcription, Storage) crashed on a missing object.
    private func link<Destination: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
                .environment(downloads)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}

// The section screens live in `Views/Settings/`; the shared provider helpers and
// the destructive reset live in an `extension SettingsView` in
// `SettingsSections.swift`. `ProviderRow`, `ProviderEditor`, `AddProviderView`,
// `SummaryModelPicker`, `ModelDownloadAlerts` and `ModelDownloadProgressRow` are
// in `SettingsProviderViews.swift`.
