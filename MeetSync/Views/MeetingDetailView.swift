//
//  MeetingDetailView.swift
//  MeetSync
//
//  The hub for a single meeting: recordings (play + transcribe), the diarized
//  transcript, editable speakers, and the AI summary. Sharing exports a
//  structured Markdown file.
//

import SwiftData
import SwiftUI

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    @State private var player = AudioPlayerService()
    @State private var txVM: TranscriptionViewModel?

    @State private var showingRecorder = false
    @State private var showingEdit = false
    @State private var transcribeTarget: Recording?
    @State private var shareItem: ShareItem?

    var body: some View {
        List {
            headerSection
            recordingsSection
            transcriptSection
            speakersSection
            summarySection
        }
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear {
            if txVM == nil {
                txVM = TranscriptionViewModel(modelContext: modelContext)
            }
        }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showingRecorder) {
            NavigationStack {
                RecorderView(meeting: meeting)
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                MeetingFormView(meeting: meeting)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .confirmationDialog(
            NSLocalizedString("detail.transcribe.choose", comment: "Choose transcription mode"),
            isPresented: Binding(
                get: { transcribeTarget != nil },
                set: { if !$0 { transcribeTarget = nil } }
            ),
            presenting: transcribeTarget
        ) { recording in
            Button(TranscriptionMode.onDevice.displayName) {
                startTranscription(recording, mode: .onDevice)
            }
            Button(TranscriptionMode.whisperAPI.displayName) {
                startTranscription(recording, mode: .whisperAPI)
            }
            Button(NSLocalizedString("common.cancel", comment: "Cancel"), role: .cancel) {}
        }
        .alert(
            NSLocalizedString("common.error", comment: "Error"),
            isPresented: Binding(
                get: { txVM?.error != nil },
                set: { if !$0 { txVM?.error = nil } }
            ),
            presenting: txVM?.error
        ) { _ in
            Button(NSLocalizedString("common.ok", comment: "OK"), role: .cancel) {}
        } message: { error in
            Text(error.errorDescription ?? "")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.createdAt.meetingDisplay)
                    .foregroundStyle(.secondary)
                if meeting.totalDuration > 0 {
                    Text(
                        String(
                            format: NSLocalizedString("detail.total_duration", comment: ""),
                            meeting.totalDuration.clockDisplay
                        )
                    )
                    .font(.subheadline)
                }
                if !meeting.notes.isEmpty {
                    Text(meeting.notes)
                        .font(.body)
                        .padding(.top, 4)
                }
            }
        }
    }

    private var recordingsSection: some View {
        Section(NSLocalizedString("detail.recordings", comment: "Recordings")) {
            ForEach(sortedRecordings) { recording in
                recordingRow(recording)
            }
            .onDelete(perform: deleteRecordings)

            Button {
                showingRecorder = true
            } label: {
                Label(
                    NSLocalizedString("detail.record_new", comment: "Record New Segment"),
                    systemImage: "mic.badge.plus"
                )
            }
        }
    }

    @ViewBuilder
    private func recordingRow(_ recording: Recording) -> some View {
        let isLoaded = player.loadedFileName == recording.fileName
        HStack(spacing: 12) {
            Button {
                togglePlay(recording)
            } label: {
                Image(systemName: (isLoaded && player.isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.recordedAt.meetingDisplay)
                    .font(.subheadline)
                Text(recording.duration.clockDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if txVM?.isTranscribing(recording) == true {
                HStack(spacing: 6) {
                    ProgressView()
                    if let phase = txVM?.phase(for: recording) {
                        Text(phase.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if recording.transcriptionStatus == .done {
                StatusBadge(status: .done)
            } else {
                Button(NSLocalizedString("detail.transcribe", comment: "Transcribe")) {
                    transcribeTarget = recording
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        let transcribed = sortedRecordings.filter { $0.transcript != nil }
        if !transcribed.isEmpty {
            Section(NSLocalizedString("detail.transcript", comment: "Transcript")) {
                ForEach(transcribed) { recording in
                    TranscriptView(
                        segments: recording.transcript?.segments ?? [],
                        speakers: meeting.speakers,
                        activeTime: player.loadedFileName == recording.fileName
                            ? player.currentTime : nil,
                        onSeek: { time in seek(recording, to: time) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var speakersSection: some View {
        if !meeting.speakers.isEmpty {
            Section {
                ForEach(meeting.speakers.sorted { $0.label < $1.label }) { speaker in
                    SpeakerRow(speaker: speaker) { try? modelContext.save() }
                }
            } header: {
                Text(NSLocalizedString("detail.speakers", comment: "Speakers"))
            } footer: {
                Text(NSLocalizedString("detail.speakers.note", comment: "Auto-detected note"))
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        Section(NSLocalizedString("detail.summary", comment: "Summary")) {
            if let summary = meeting.summary {
                SummaryView(summary: summary)
                summaryButton(regenerate: true)
            } else if txVM?.isSummarizing == true {
                HStack {
                    ProgressView()
                    Text(NSLocalizedString("detail.summarizing", comment: "Generating..."))
                        .foregroundStyle(.secondary)
                }
            } else {
                if meeting.hasAnyTranscript {
                    summaryButton(regenerate: false)
                } else {
                    Text(NSLocalizedString("detail.summary.needs_transcript", comment: ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summaryButton(regenerate: Bool) -> some View {
        Button {
            generateSummary()
        } label: {
            Label(
                regenerate
                    ? NSLocalizedString("detail.summary.regenerate", comment: "Regenerate")
                    : NSLocalizedString("detail.summary.generate", comment: "Generate Summary"),
                systemImage: "sparkles"
            )
        }
        .disabled(txVM?.isSummarizing == true)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showingEdit = true
                } label: {
                    Label(NSLocalizedString("common.edit", comment: "Edit"), systemImage: "pencil")
                }
                Button {
                    share()
                } label: {
                    Label(
                        NSLocalizedString("detail.share", comment: "Share"),
                        systemImage: "square.and.arrow.up"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Helpers

    private var sortedRecordings: [Recording] {
        meeting.recordings.sorted { $0.recordedAt < $1.recordedAt }
    }

    private func togglePlay(_ recording: Recording) {
        do {
            if player.loadedFileName == recording.fileName {
                player.togglePlayPause()
            } else {
                try player.load(fileName: recording.fileName)
                player.play()
            }
        } catch let error as AppError {
            txVM?.error = error
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }

    private func seek(_ recording: Recording, to time: TimeInterval) {
        do {
            if player.loadedFileName != recording.fileName {
                try player.load(fileName: recording.fileName)
            }
            player.seek(to: time)
            player.play()
        } catch let error as AppError {
            txVM?.error = error
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }

    private func startTranscription(_ recording: Recording, mode: TranscriptionMode) {
        transcribeTarget = nil
        guard let txVM else { return }
        Task {
            await txVM.transcribe(recording, language: meeting.language, mode: mode)
        }
    }

    private func generateSummary() {
        guard let txVM else { return }
        Task {
            await txVM.generateSummary(for: meeting, provider: settings.aiProvider)
        }
    }

    private func deleteRecordings(at offsets: IndexSet) {
        let targets = offsets.map { sortedRecordings[$0] }
        for recording in targets {
            if player.loadedFileName == recording.fileName { player.stop() }
            AudioFileStore.delete(fileName: recording.fileName)
            modelContext.delete(recording)
        }
        try? modelContext.save()
    }

    private func share() {
        do {
            let url = try MeetingExport.temporaryFile(for: meeting)
            shareItem = ShareItem(url: url)
        } catch {
            txVM?.error = .audioError(error.localizedDescription)
        }
    }
}

/// Inline-editable speaker name with its color swatch.
private struct SpeakerRow: View {
    @Bindable var speaker: Speaker
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: speaker.color))
                .frame(width: 14, height: 14)
            TextField(speaker.label, text: $speaker.name)
                .onSubmit(onCommit)
            Text(speaker.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
