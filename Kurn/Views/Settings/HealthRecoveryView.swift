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

    typealias DegradedItem = HealthRecoveryAggregation.DegradedItem

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
        HealthRecoveryAggregation.isEmpty(
            recoveryNeeded: recoveryNeeded,
            stalledTranscriptions: stalledTranscriptions,
            degraded: degraded,
            quarantineItems: quarantineItems,
            corruptModels: corruptModels,
            recentFailures: recentFailures
        )
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
        recoveryNeeded = (try? modelContext.fetch(HealthRecoveryAggregation.recoveryNeededDescriptor())) ?? []
        stalledTranscriptions = (try? modelContext.fetch(
            HealthRecoveryAggregation.stalledTranscriptionsDescriptor()
        )) ?? []

        let allTranscripts = (try? modelContext.fetch(FetchDescriptor<Transcript>())) ?? []
        degraded = HealthRecoveryAggregation.degradedItems(in: allTranscripts)

        quarantineItems = await Task.detached(priority: .utility) {
            RecordingQuarantine.items()
        }.value

        corruptModels = HealthRecoveryAggregation.corruptModels(in: downloads.installedModels)

        recentFailures = HealthRecoveryAggregation.recentFailures(
            in: ReliabilityEventStore.recentEvents(limit: HealthRecoveryAggregation.recentFailureWindow)
        )
    }
}
