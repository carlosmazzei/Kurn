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
//  destructive reset. Key status and the provider-selection invariants live in
//  `AppSettings.credentials` / `AppSettings+ProviderSelection.swift`.
//

import SwiftData
import KurnCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) var settings
    @Environment(\.modelContext) var modelContext
    @Environment(\.dismiss) var dismiss
    /// Optional: Settings also renders in the security cover window, which
    /// does not inject the transcription coordinator.
    @Environment(TranscriptionCoordinator.self) var transcription: TranscriptionCoordinator?
    @Environment(ChatConversationHost.self) var chatConversations: ChatConversationHost?

    /// The FluidAudio download state shared by the Transcription, Recording and
    /// Storage screens. Owned by `KurnApp` rather than here: the diarization
    /// models are also offered from a meeting's transcript, and a second
    /// controller would track a download this one knows nothing about.
    @Environment(ModelDownloadController.self) private var downloads

    @State var showingDeleteConfirm = false
    /// Set when "Delete all data" fails to erase the store, so the failure
    /// surfaces instead of the wipe silently doing nothing.
    @State var dataError: AppError?

    /// "N providers" is read through `settings.configuredProviders`, which
    /// already re-derives on any key change via `credentials`.
    private var providerCount: Int { settings.configuredProviders.count }

    /// The used-space figure shown as the Storage row's value — the same
    /// number the Storage screen computes for "Audio usage".
    @State private var storageUsed = ""

    var body: some View {
        Form {
            Section {
                link(PrivacyCloudCopy.text("title"), systemImage: "lock.shield",
                     identifier: "settings.link.privacyCloud") {
                    PrivacyCloudSettingsView()
                }
                link(
                    NSLocalizedString("settings.providers", comment: "AI Providers"),
                    systemImage: "cpu",
                    value: providerCount > 0 ? "\(providerCount)" : nil,
                    identifier: "settings.link.providers"
                ) {
                    ProvidersSettingsView()
                }
            }

            Section {
                link(
                    NSLocalizedString("settings.recording", comment: "Recording"),
                    systemImage: "mic",
                    identifier: "settings.link.recording"
                ) {
                    RecordingSettingsView()
                }
                link(
                    NSLocalizedString("settings.transcription", comment: "Transcription"),
                    systemImage: "waveform",
                    value: TranscriptionPreset.current(settings: settings)?.title
                        ?? NSLocalizedString("settings.preset.custom", comment: "Custom preset"),
                    identifier: "settings.link.transcription"
                ) {
                    TranscriptionSettingsView()
                }
            } header: {
                Text(NSLocalizedString("settings.group.capture", comment: "Capture group"))
            }

            Section {
                link(
                    NSLocalizedString("settings.summary", comment: "Summary"),
                    systemImage: "sparkles",
                    identifier: "settings.link.summary"
                ) {
                    SummarySettingsView()
                }
                link(
                    KnowledgeSettingsCopy.text("title"),
                    systemImage: "book",
                    value: settings.knowledgeEnabled
                        ? NSLocalizedString("common.on", comment: "On")
                        : NSLocalizedString("common.off", comment: "Off"),
                    identifier: "settings.link.knowledge"
                ) {
                    KnowledgeSettingsView()
                }
                link(
                    NSLocalizedString("settings.read_aloud.title", comment: "Read Aloud"),
                    systemImage: "speaker.wave.2",
                    identifier: "settings.link.readAloud"
                ) {
                    ReadAloudSettingsView()
                }
            } header: {
                Text(NSLocalizedString("settings.group.intelligence", comment: "Intelligence group"))
            }

            Section {
                link(
                    NSLocalizedString("tag.title", comment: "Tags"),
                    systemImage: "tag",
                    identifier: "settings.link.tags"
                ) {
                    TagsSettingsView()
                }
                link(
                    NSLocalizedString("settings.semantic_search_title", comment: "Search"),
                    systemImage: "magnifyingglass",
                    identifier: "settings.link.search"
                ) {
                    SemanticSearchSettingsView()
                }
                link(
                    NSLocalizedString("settings.storage", comment: "Storage"),
                    systemImage: "internaldrive",
                    value: storageUsed.isEmpty ? nil : storageUsed,
                    identifier: "settings.link.storage"
                ) {
                    StorageSettingsView()
                }
            } header: {
                Text(NSLocalizedString("settings.group.library", comment: "Library group"))
            }

            Section {
                link(
                    NSLocalizedString("health.title", comment: "Health & Recovery"),
                    systemImage: "waveform.path.ecg",
                    identifier: "settings.link.health"
                ) {
                    HealthRecoveryView()
                }
                link(
                    NSLocalizedString("settings.diagnostics", comment: "Diagnostics"),
                    systemImage: "info.circle",
                    identifier: "settings.link.diagnostics"
                ) {
                    DiagnosticsSettingsView()
                }
                link(
                    NSLocalizedString("usage_insights.title", comment: "Usage"),
                    systemImage: "chart.bar",
                    identifier: "settings.link.usage"
                ) {
                    UsageInsightsView()
                }
                link(
                    NSLocalizedString("settings.about", comment: "About Kurn"),
                    systemImage: "heart",
                    identifier: "settings.link.about"
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
        .navigationBarTitleDisplayMode(.large)
        .environment(downloads)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
            }
        }
        .task { storageUsed = AudioFileStore.formattedSize(AudioFileStore.totalAudioBytes()) }
        // Key writes re-apply this themselves (`AppSettings.credentials`);
        // running it on appear also catches what no write announces, such as
        // the on-device model becoming unavailable.
        .onAppear { settings.ensureProviderSelectionsAreUsable() }
        .kurnDialog(
            isPresented: $showingDeleteConfirm,
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: Theme.destructive,
            title: NSLocalizedString("settings.delete_all.confirm", comment: "Confirm delete all"),
            message: NSLocalizedString("settings.delete_all.message", comment: ""),
            primaryTitle: NSLocalizedString("settings.delete_all", comment: "Delete All Data"),
            primaryRole: .destructive,
            primaryAction: { Task { await authorizeAndDeleteAllData() } },
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
        value: String? = nil,
        identifier: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
                .environment(downloads)
        } label: {
            HStack(spacing: 12) {
                SettingsRowIcon(systemImage: systemImage)
                Text(title)
                Spacer()
                if let value {
                    Text(value).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }
}

// The section screens live in `Views/Settings/`; the shared provider helpers and
// the destructive reset live in an `extension SettingsView` in
// `SettingsSections.swift`. `ProviderRow`, `ProviderEditor`, `AddProviderView`,
// `SummaryModelPicker`, `ModelDownloadAlerts` and `ModelDownloadProgressRow` are
// in `SettingsProviderViews.swift`.
