import KurnCore
import SwiftUI

struct KnowledgeSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(KnowledgeSettingsCoordinator.self) private var management: KnowledgeSettingsCoordinator?
    @State private var sourceIDs: Set<UUID> = []
    @State private var showingSources = false
    @State private var rebuild = false
    @State private var plan: KnowledgeBackfillPlan?
    @State private var coverage: KnowledgeScopedMaintenanceReport?
    @State private var action: Action?
    @State private var epoch = 0
    @State private var error: AppError?
    @State private var confirming = false
    @State private var resetting = false
    private enum Action: Hashable { case preview, coverage, pages }

    var body: some View {
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
            let token = epoch
            let requested = action
            if let requested { await perform(requested) }
            if token == epoch && action == requested { action = nil }
        }
        .onChange(of: sourceIDs) { _, _ in invalidate() }
        .onChange(of: rebuild) { _, _ in invalidate() }
        .onChange(of: settings.knowledgeEnabled) { _, _ in invalidate() }
        .onChange(of: settings.knowledgeControls) { _, _ in
            sourceIDs = Set(sourceIDs.filter { settings.knowledgeControls?.allows($0) == true }); invalidate()
        }
        .onDisappear { invalidate() }
        .errorAlert($error)
        .alert(KnowledgeSettingsCopy.text("confirm"), isPresented: $confirming) {
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
            Button(KnowledgeSettingsCopy.text("start")) { if let plan { management?.start(plan) } }
                .accessibilityIdentifier("knowledge.settings.confirm")
        } message: { Text(KnowledgeSettingsCopy.text("local_cost")) }
        .alert(KnowledgeSettingsCopy.text("reset"), isPresented: $resetting) {
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
            Button(KnowledgeSettingsCopy.text("reset")) { do { try settings.resetKnowledgeControls() } catch { reportError() } }
        } message: { Text(KnowledgeSettingsCopy.text("reset_detail")) }
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
                LabeledContent(KnowledgeSettingsCopy.text("provider"), value: settings.knowledgeProvider?.displayName ?? KnowledgeSettingsCopy.text("unavailable"))
                if controls.providerID != AIProvider.appleOnDevice.id {
                    Button(KnowledgeSettingsCopy.text("use_local")) { var next = controls; next.providerID = AIProvider.appleOnDevice.id; save(next) }
                }
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
                    Button(KnowledgeSettingsCopy.text("preview")) { action = .preview }
                        .accessibilityIdentifier("knowledge.settings.preview")
                    Button(KnowledgeSettingsCopy.text("coverage")) { action = .coverage }
                    Button(KnowledgeSettingsCopy.text("pages")) { action = .pages }
                }
                .disabled(!settings.knowledgeEnabled || sourceIDs.isEmpty || action != nil || management.progress?.isRunning == true)
            } footer: { Text(KnowledgeSettingsCopy.text("selection_detail")) }
            if let plan {
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
                    Text(KnowledgeSettingsCopy.text("local_cost"))
                    if plan.requiresRebuild { Text(KnowledgeSettingsCopy.text("recompile_required")) }
                    Button(KnowledgeSettingsCopy.text("start")) { confirming = true }
                        .disabled(plan.pending.isEmpty || plan.requiresRebuild || controls.isPaused || !management.canCompile || management.progress?.isRunning == true)
                        .accessibilityIdentifier("knowledge.settings.start")
                    if !management.canCompile { Text(OnDeviceModelAvailability.unavailableReason ?? KnowledgeSettingsCopy.text("unavailable")) }
                }
            }
            if let coverage { KnowledgeCoverageSection(report: coverage.report) }
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
    private func save(_ controls: KnowledgeControls) { do { try settings.saveKnowledgeControls(controls) } catch { reportError() } }
    private func invalidate() { epoch += 1; action = nil; plan = nil; coverage = nil }
    private func reportError() { error = .resourceUnavailable(KnowledgeSettingsCopy.text("failed")) }
    private func perform(_ requested: Action) async {
        guard let management else { return }
        let token = epoch
        let ids = sourceIDs
        let controls = settings.knowledgeControls
        do {
            switch requested {
            case .preview:
                let result = try await management.preview(meetingIDs: ids, rebuild: rebuild)
                guard token == epoch, settings.knowledgeControls == controls, !Task.isCancelled else { return }; plan = result
            case .coverage:
                let result = try await management.coverage(meetingIDs: ids)
                guard token == epoch, settings.knowledgeControls == controls, !Task.isCancelled else { return }; coverage = result
            case .pages: try await management.rebuildPages(meetingIDs: ids)
            }
        } catch { if token == epoch && !Task.isCancelled { reportError() } }
    }
}

enum KnowledgeSettingsCopy {
    static func text(_ key: String) -> String { NSLocalizedString("knowledge.settings." + key, comment: "Knowledge settings") }
}
