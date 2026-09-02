//
//  HealthRecoveryView.swift
//  Kurn
//
//  H9 PR 23: a single "repair surface, not analytics" screen aggregating six
//  conditions already tracked individually elsewhere in the app — pending
//  capture recovery, quarantined audio, degraded transcripts, failed/deferred
//  transcription jobs, corrupt on-device models, and recent failure codes —
//  so a user doesn't have to know which of six different screens to check.
//  Every action here calls the exact same recovery function its per-item
//  counterpart already does (`RecordingRecovery.retryRecovery`,
//  `RecordingQuarantine.recover`/`.delete`, `TranscriptionViewModel
//  .retryCorrection`/`.startTranscription`, `ModelDownloadController
//  .deleteModel`) rather than reimplementing recovery logic — this screen
//  only aggregates and dispatches.
//

import SwiftUI
import SwiftData
import KurnCore

struct HealthRecoveryView: View {
    // Not `private` — `HealthRecoveryView+Sections.swift` (split out to keep
    // this file under SwiftLint's type-length warning) reads/calls these.
    @Environment(\.modelContext) var modelContext
    @Environment(AppSettings.self) var settings
    @Environment(TranscriptionViewModel.self) private var sharedTxVM
    @Environment(ModelDownloadController.self) var downloads

    var txVM: TranscriptionViewModel? { sharedTxVM }

    /// One decoded, warning-carrying `PipelineReport` alongside the recording
    /// it came from — `pipelineReportData` is opaque JSON, so `Transcript`
    /// can't be filtered by a SwiftData predicate; every transcript is
    /// fetched and decoded here instead.
    struct DegradedItem: Identifiable {
        var id: UUID { recording.id }
        let recording: Recording
        let report: PipelineReport
    }

    @State var recoveryNeeded: [Recording] = []
    @State var stalledTranscriptions: [Recording] = []
    @State var degraded: [DegradedItem] = []
    @State var quarantineItems: [QuarantinedRecording] = []
    @State var corruptModels: [ModelStore.InstalledModel] = []
    @State var recentFailures: [ReliabilityEvent] = []

    @State var selectedMeeting: Meeting?
    @State var actionError: AppError?
    @State var pendingQuarantineDeletion: QuarantinedRecording?
    @State var quarantineShareItem: ShareItem?

    var isEmpty: Bool {
        recoveryNeeded.isEmpty && stalledTranscriptions.isEmpty && degraded.isEmpty
            && quarantineItems.isEmpty && corruptModels.isEmpty && recentFailures.isEmpty
    }

    var body: some View {
        List {
            if isEmpty {
                Section {
                    Label(
                        NSLocalizedString("health.all_clear", comment: "Nothing needs attention"),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(Theme.textSecondary)
                }
            } else {
                recoverySection
                stalledSection
                degradedSection
                quarantineSection
                modelsSection
                eventsSection
            }
        }
        .navigationTitle(NSLocalizedString("health.title", comment: "Health & Recovery"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            downloads.refreshInstalledModels()
            await refresh()
        }
        .navigationDestination(item: $selectedMeeting) { meeting in
            MeetingDetailView(meeting: meeting)
        }
        .errorAlert($actionError)
        .sheet(item: $quarantineShareItem) { item in
            ActivityView(items: item.urls)
        }
        .kurnDialog(
            isPresented: Binding(
                get: { pendingQuarantineDeletion != nil },
                set: { if !$0 { pendingQuarantineDeletion = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("quarantine.delete_confirm", comment: "Confirm quarantine delete"),
            message: NSLocalizedString("quarantine.delete_message", comment: "Deleting is permanent"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                if let item = pendingQuarantineDeletion {
                    RecordingQuarantine.delete(item)
                    Task { await refresh() }
                }
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: Binding(
                get: { downloads.pendingModelDeletion != nil },
                set: { if !$0 { downloads.pendingModelDeletion = nil } }
            ),
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.models.delete_confirm", comment: "Confirm delete model"),
            message: NSLocalizedString("settings.models.delete_message", comment: "Re-download later"),
            primaryTitle: NSLocalizedString("settings.models.delete", comment: "Delete model"),
            primaryRole: .destructive,
            primaryAction: {
                if let model = downloads.pendingModelDeletion {
                    downloads.deleteModel(model, settings: settings)
                    Task { await refresh() }
                }
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    // MARK: - Actions

    func openMeeting(for recording: Recording) {
        selectedMeeting = recording.meeting
    }

    func retryCaptureRecovery(_ recording: Recording) {
        if let error = RecordingRecovery.retryRecovery(for: recording, context: modelContext) {
            actionError = error
        }
        Task { await refresh() }
    }

    func retryTranscription(_ recording: Recording) {
        guard let txVM, let meeting = recording.meeting else { return }
        txVM.resetAutomaticResumeBudget(for: recording)
        txVM.startTranscription(recording, language: meeting.language, config: settings.pipelineConfiguration)
    }

    func retryCorrection(_ recording: Recording) {
        guard let txVM, let meeting = recording.meeting else { return }
        txVM.retryCorrection(recording, language: meeting.language, config: settings.pipelineConfiguration)
    }

    func recoverQuarantined(_ item: QuarantinedRecording) {
        if let error = RecordingQuarantine.recover(item, context: modelContext) {
            actionError = error
            return
        }
        Task { await refresh() }
    }

    func exportQuarantined(_ item: QuarantinedRecording) {
        do {
            quarantineShareItem = ShareItem(urls: [try RecordingQuarantine.exportURL(for: item)])
        } catch {
            actionError = .audioError(error.localizedDescription)
        }
    }

    // MARK: - Loading

    func refresh() async {
        let recoveryRaw = RecordingCaptureState.recoveryNeeded.rawValue
        let readyRaw = RecordingCaptureState.ready.rawValue
        let failedRaw = TranscriptionStatus.failed.rawValue
        let pendingRaw = TranscriptionStatus.pending.rawValue

        let recoveryDescriptor = FetchDescriptor<Recording>(
            predicate: #Predicate { $0.captureStateRaw == recoveryRaw },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        recoveryNeeded = (try? modelContext.fetch(recoveryDescriptor)) ?? []

        let stalledDescriptor = FetchDescriptor<Recording>(
            predicate: #Predicate {
                $0.captureStateRaw == readyRaw
                    && ($0.transcriptionStatusRaw == failedRaw || $0.transcriptionStatusRaw == pendingRaw)
            },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        stalledTranscriptions = (try? modelContext.fetch(stalledDescriptor)) ?? []

        let allTranscripts = (try? modelContext.fetch(FetchDescriptor<Transcript>())) ?? []
        degraded = allTranscripts.compactMap { transcript in
            guard let report = transcript.pipelineReport, report.hasWarnings,
                  let recording = transcript.recording else { return nil }
            return DegradedItem(recording: recording, report: report)
        }

        quarantineItems = await Task.detached(priority: .utility) {
            RecordingQuarantine.items()
        }.value

        corruptModels = downloads.installedModels.filter {
            if case .corrupt = $0.verificationState { return true }
            return false
        }

        recentFailures = ReliabilityEventStore.recentEvents(limit: 100)
            .filter { $0.outcome == .failed }
    }
}
