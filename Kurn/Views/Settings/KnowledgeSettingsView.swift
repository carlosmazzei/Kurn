import KurnCore
import SwiftUI

struct KnowledgeSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(KnowledgeSettingsCoordinator.self) private var management: KnowledgeSettingsCoordinator?
    @Environment(KnowledgeDeletionCoordinator.self) private var deletion: KnowledgeDeletionCoordinator?
    @State private var sourceIDs: Set<UUID> = []
    @State private var showingSources = false
    @State private var rebuild = false
    @State private var model = KnowledgeSettingsViewModel()
    @State private var action: PendingAction?
    private struct PendingAction: Hashable {
        let id = UUID()
        let action: KnowledgeSettingsViewModel.SettingsAction
    }
    @State private var confirming = false
    @State private var resetting = false
    @State private var deleting = false
    @State private var pendingCloudProvider: AIProvider?

    var body: some View {
        @Bindable var presentation = model
        Group {
            if let management, let controls = settings.knowledgeControls {
                form(controls, management: management)
            } else if management != nil {
                ContentUnavailableView {
                    Label(KnowledgeSettingsCopy.text("unreadable"), systemImage: "exclamationmark.triangle")
                } actions: { Button(KnowledgeSettingsCopy.text("reset")) { resetting = true } }
            } else {
                ContentUnavailableView(KnowledgeSettingsCopy.text("unlock"), systemImage: "lock")
            }
        }
        .navigationTitle(KnowledgeSettingsCopy.text("title"))
        .sheet(isPresented: $showingSources) {
            KnowledgeMeetingSelectionView(selectedIDs: sourceIDs) { sourceIDs = $0; showingSources = false }
        }
        .task(id: action) {
            guard let action, let management else { return }
            await model.perform(action.action, meetingIDs: sourceIDs, rebuild: rebuild, settings: settings,
                operations: .init(preview: { try await management.preview(meetingIDs: $0, rebuild: $1) },
                    coverage: { try await management.coverage(meetingIDs: $0) }, pages: { try await management.rebuildPages(meetingIDs: $0) }))
        }
        .onChange(of: sourceIDs) { _, _ in invalidate() }
        .onChange(of: rebuild) { _, _ in invalidate() }
        .onChange(of: settings.knowledgeEnabled) { _, _ in invalidate() }
        .onChange(of: settings.knowledgeControls) { _, _ in
            sourceIDs = Set(sourceIDs.filter { settings.knowledgeControls?.allows($0) == true }); invalidate()
        }
        .onDisappear { invalidate() }
        .errorAlert($presentation.error)
        .kurnDialog(
            isPresented: Binding(get: { pendingCloudProvider != nil }, set: { if !$0 { pendingCloudProvider = nil } }),
            iconSystemName: "icloud.and.arrow.up",
            iconTint: Theme.info,
            title: KnowledgeSettingsCopy.text("cloud_title"),
            message: String(format: KnowledgeSettingsCopy.text("cloud_message"), pendingCloudProvider?.displayName ?? "",
                            PrivacyCloudCopy.host(of: pendingCloudProvider?.baseURLString ?? "")),
            primaryTitle: KnowledgeSettingsCopy.text("cloud_allow"),
            primaryAction: {
                guard let provider = pendingCloudProvider else { return }
                pendingCloudProvider = nil
                Task { await allowCloud(provider) }
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: $confirming,
            iconSystemName: "books.vertical",
            iconTint: Theme.info,
            title: KnowledgeSettingsCopy.text("confirm"),
            message: costText,
            primaryTitle: KnowledgeSettingsCopy.text("start"),
            primaryAction: { if let plan = model.plan { management?.start(plan) } },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: $resetting,
            iconSystemName: "arrow.counterclockwise",
            iconTint: Theme.warning,
            title: KnowledgeSettingsCopy.text("reset"),
            message: KnowledgeSettingsCopy.text("reset_detail"),
            primaryTitle: KnowledgeSettingsCopy.text("reset"),
            primaryRole: .destructive,
            primaryAction: { do { try settings.resetKnowledgeControls() } catch { model.reportError() } },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: $deleting,
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: Theme.destructive,
            title: KnowledgeSettingsCopy.text("delete"),
            message: KnowledgeSettingsCopy.text("delete_detail"),
            primaryTitle: KnowledgeSettingsCopy.text("delete"),
            primaryRole: .destructive,
            primaryAction: { Task { await deleteCorpus() } },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    /// Destroying derived content re-authenticates like "Delete all data".
    private func deleteCorpus() async {
        guard let deletion else { return }
        await model.deleteCorpus(authorize: {
            switch await SensitiveActionAuthorizer().authorize(requireAuth: settings.requireAuthForRecordings) {
            case .authorized: return true
            case .cancelled: return false
            case .denied(let error): model.error = error; return false
            }
        }, delete: { try await deletion.deleteCorpus() })
    }

    private func form(_ controls: KnowledgeControls, management: KnowledgeSettingsCoordinator) -> some View {
        Form {
            Section {
                Toggle(KnowledgeSettingsCopy.text("enable"), isOn: Binding(get: { settings.knowledgeEnabled }, set: { settings.knowledgeEnabled = $0 }))
                    .accessibilityIdentifier("knowledge.settings.enabled")
                Toggle(KnowledgeSettingsCopy.text("automatic"), isOn: binding(controls, \.automaticCompilation))
                    .disabled(!settings.knowledgeEnabled).accessibilityIdentifier("knowledge.settings.automatic")
                Toggle(KnowledgeSettingsCopy.text("pause"), isOn: binding(controls, \.isPaused))
                    .disabled(!settings.knowledgeEnabled).accessibilityIdentifier("knowledge.settings.paused")
                Toggle(KnowledgeSettingsCopy.text("export"), isOn: Binding(get: { settings.knowledgeExportEnabled },
                                                                           set: { enabled in Task { await setExport(enabled) } }))
                    .disabled(!settings.knowledgeEnabled).accessibilityIdentifier("knowledge.settings.export")
                Picker(KnowledgeSettingsCopy.text("provider"), selection: Binding(
                    get: { controls.providerID },
                    set: { id in choose(id, controls: controls) }
                )) {
                    ForEach(knowledgeProviders) { Text(verbatim: $0.displayName).tag($0.id) }
                }
                .accessibilityIdentifier("knowledge.settings.provider")
                NavigationLink(KnowledgeSettingsCopy.text("scope")) { KnowledgeScopeSettingsView(controls: controls) }
                    .accessibilityIdentifier("knowledge.settings.scope")
            } footer: { Text(KnowledgeSettingsCopy.text("automatic_detail")) }
            Section {
                Button { showingSources = true } label: { Label(KnowledgeSettingsCopy.text("choose"), systemImage: "checklist") }
                    .accessibilityIdentifier("knowledge.settings.choose")
                    .disabled(!settings.knowledgeEnabled || management.progress?.isRunning == true)
                Text(String(format: KnowledgeSettingsCopy.text("selected"), sourceIDs.count))
                Group {
                    Toggle(KnowledgeSettingsCopy.text("recompile"), isOn: $rebuild)
                    Button(KnowledgeSettingsCopy.text("preview")) { action = .init(action: .preview) }
                        .accessibilityIdentifier("knowledge.settings.preview")
                    Button(KnowledgeSettingsCopy.text("coverage")) { action = .init(action: .coverage) }
                    Button(KnowledgeSettingsCopy.text("pages")) { action = .init(action: .pages) }
                }
                .disabled(!settings.knowledgeEnabled || sourceIDs.isEmpty || model.isBusy || management.progress?.isRunning == true)
            } footer: { Text(KnowledgeSettingsCopy.text("selection_detail")) }
            if let plan = model.plan {
                Section(KnowledgeSettingsCopy.text("preview")) {
                    ForEach(plan.read.sources) { source in
                        VStack(alignment: .leading) {
                            Text(verbatim: source.title)
                            Text(KnowledgeSettingsCopy.text(source.segments == 0 ? "no_transcript" : (source.isCurrent ? "current" : "needs_work")))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(String(format: KnowledgeSettingsCopy.text("planned"), plan.pending.count))
                        .accessibilityIdentifier("knowledge.settings.plan")
                    Text(costText)
                    if plan.requiresRebuild { Text(KnowledgeSettingsCopy.text("recompile_required")) }
                    Button(KnowledgeSettingsCopy.text("start")) { confirming = true }
                        .disabled(plan.pending.isEmpty || plan.requiresRebuild || controls.isPaused || !management.canCompile || management.progress?.isRunning == true)
                        .accessibilityIdentifier("knowledge.settings.start")
                    if !management.canCompile { Text(OnDeviceModelAvailability.unavailableReason ?? KnowledgeSettingsCopy.text("unavailable")) }
                }
            }
            if let coverage = model.coverage { KnowledgeCoverageSection(report: coverage.report) }
            Section {
                Button(KnowledgeSettingsCopy.text("delete"), role: .destructive) { deleting = true }
                    .disabled(deletion == nil || model.isDeletingCorpus || deletion?.isDeletingCorpus == true
                        || management.progress?.isRunning == true)
                    .accessibilityIdentifier("knowledge.settings.delete")
                if model.isDeletingCorpus { ProgressView() }
                if model.corpusDeleted {
                    Text(KnowledgeSettingsCopy.text("deleted")).accessibilityIdentifier("knowledge.settings.deleted")
                }
            } footer: { Text(KnowledgeSettingsCopy.text("delete_footer")) }
            if let progress = management.progress, management.progressControls == controls, management.progressMeetingIDs == sourceIDs {
                Section(KnowledgeSettingsCopy.text("progress")) {
                    Text(String(format: KnowledgeSettingsCopy.text("progress_counts"), progress.completed, progress.deferred, progress.failed))
                    if progress.isRunning { ProgressView() }
                    if management.failed { Text(KnowledgeSettingsCopy.text("failed")) }
                }
            } else if management.progress?.isRunning == true {
                Section(KnowledgeSettingsCopy.text("progress")) { ProgressView() }
            }
        }
    }

    private func binding(_ controls: KnowledgeControls, _ key: WritableKeyPath<KnowledgeControls, Bool>) -> Binding<Bool> {
        Binding(get: { settings.knowledgeControls?[keyPath: key] ?? false }, set: { value in var next = controls; next[keyPath: key] = value; save(next) })
    }
    /// On-device plus every keyed cloud provider that can generate text with a model set.
    private var knowledgeProviders: [AIProvider] {
        settings.providers.filter {
            $0.kind == .appleOnDevice
                || ($0.supportsSummarization && settings.credentials.hasKey(for: $0) && !settings.summaryModel(for: $0).isEmpty)
        }
    }

    private var costText: String {
        guard let provider = settings.knowledgeProvider, provider.kind != .appleOnDevice else {
            return KnowledgeSettingsCopy.text("local_cost")
        }
        return String(format: KnowledgeSettingsCopy.text("cloud_cost"), provider.displayName)
    }

    /// Letting Knowledge leave the protected store re-authenticates like "Delete all data";
    /// turning export off never needs it.
    private func setExport(_ enabled: Bool) async {
        guard enabled else { settings.knowledgeExportEnabled = false; return }
        switch await SensitiveActionAuthorizer().authorize(requireAuth: settings.requireAuthForRecordings) {
        case .authorized: settings.knowledgeExportEnabled = true
        case .cancelled: return
        case .denied(let error): model.error = error
        }
    }

    /// Redirecting future transcripts off the device re-authenticates like
    /// "Delete all data", so an unlocked library alone is not enough.
    private func allowCloud(_ provider: AIProvider) async {
        switch await SensitiveActionAuthorizer().authorize(requireAuth: settings.requireAuthForRecordings) {
        case .authorized:
            guard let controls = settings.knowledgeControls else { return }
            settings.grantCloudConsent(provider, for: .automatic)
            choose(provider.id, controls: controls)
        case .cancelled: return
        case .denied(let error): model.error = error
        }
    }

    /// A cloud provider without the automatic grant asks first (CLAUDE.md, "Cloud consent").
    private func choose(_ id: String, controls: KnowledgeControls) {
        guard let provider = settings.providers.first(where: { $0.id == id }) else { return }
        guard settings.allowsCloud(provider, for: .automatic) else { pendingCloudProvider = provider; return }
        var next = controls
        next.providerID = id
        save(next)
    }

    private func save(_ controls: KnowledgeControls) { do { try settings.saveKnowledgeControls(controls) } catch { model.reportError() } }
    private func invalidate() { action = nil; model.invalidate() }
}

enum KnowledgeSettingsCopy {
    static func text(_ key: String) -> String { NSLocalizedString("knowledge.settings." + key, comment: "Knowledge settings") }
}
