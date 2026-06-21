//
//  MeetingDetailView.swift
//  MeetSync
//
//  The hub for a single meeting, organized into three tabs (Recordings,
//  Transcript, Summary) per the iOS design. Recordings can be played and
//  transcribed; the transcript is speaker-filterable; the summary is generated
//  by the configured AI provider. Sharing exports a structured Markdown file.
//

import SwiftData
import SwiftUI

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting

    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    enum Tab: Hashable { case recordings, transcript, summary }

    @State private var player = AudioPlayerService()
    @State private var txVM: TranscriptionViewModel?
    @State private var tab: Tab = .recordings

    @State private var showingRecorder = false
    @State private var showingEdit = false
    @State private var shareItem: ShareItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.separator)
            tabContent
            tabBar
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear {
            if txVM == nil { txVM = TranscriptionViewModel(modelContext: modelContext) }
        }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showingRecorder) {
            NavigationStack { RecorderView(meeting: meeting) }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack { MeetingFormView(meeting: meeting) }
        }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(meeting.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(meeting.createdAt.meetingDisplay)
                metaDot
                Text(String(format: NSLocalizedString("detail.segment_count", comment: ""), meeting.recordings.count))
                if meeting.totalDuration > 0 {
                    metaDot
                    Text(meeting.totalDuration.clockDisplay)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var metaDot: some View {
        Circle().fill(Theme.textTertiary).frame(width: 3, height: 3)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .recordings:
            recordingsList
        case .transcript:
            ScrollView {
                transcriptTab.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            }
        case .summary:
            ScrollView {
                summaryTab.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            }
        }
    }

    // MARK: - Recordings tab (List, so swipe-to-delete works)

    private var recordingsList: some View {
        List {
            sectionLabel(NSLocalizedString("detail.recordings", comment: "Recordings"))
                .clearListRow(insets: EdgeInsets(top: 16, leading: 20, bottom: 4, trailing: 20))
            ForEach(Array(sortedRecordings.enumerated()), id: \.element.id) { index, recording in
                segmentRow(recording, index: index)
                    .clearListRow(insets: EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteRecording(recording) } label: {
                            Label(NSLocalizedString("common.delete", comment: "Delete"), systemImage: "trash")
                        }
                    }
            }
            addSegmentButton
                .clearListRow(insets: EdgeInsets(top: 8, leading: 20, bottom: 24, trailing: 20))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func segmentRow(_ recording: Recording, index: Int) -> some View {
        let isLoaded = player.loadedFileName == recording.fileName
        return HStack(spacing: 12) {
            Button { togglePlay(recording) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.fill)
                        .frame(width: 34, height: 34)
                    Image(systemName: (isLoaded && player.isPlaying) ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: NSLocalizedString("detail.recording_n", comment: ""), index + 1))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(recording.recordedAt.meetingDisplay) · \(recording.duration.clockDisplay)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)

            if txVM?.isTranscribing(recording) == true {
                HStack(spacing: 6) {
                    ProgressView()
                    if let phase = txVM?.phase(for: recording) {
                        Text(phase.displayName).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            } else if recording.transcriptionStatus == .done {
                StatusBadge(status: .done)
            } else {
                Button {
                    startTranscription(recording, mode: settings.defaultMode)
                } label: {
                    StatusBadge(status: .none)
                }
                .buttonStyle(.plain)
            }
        }
        .meetsyncCard(padding: 14, cornerRadius: 16)
    }

    private var addSegmentButton: some View {
        Button { showingRecorder = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.12)).frame(width: 34, height: 34)
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                }
                Text(NSLocalizedString("detail.add_segment", comment: "Add segment"))
                    .font(.system(size: 15)).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Theme.textTertiary.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcript tab

    @ViewBuilder
    private var transcriptTab: some View {
        let transcribed = sortedRecordings.filter { $0.transcript != nil }
        if transcribed.isEmpty {
            placeholder(
                icon: "text.alignleft",
                title: NSLocalizedString("detail.transcript.empty.title", comment: ""),
                subtitle: NSLocalizedString("detail.transcript.empty.subtitle", comment: "")
            )
        } else {
            TranscriptTab(
                meeting: meeting,
                recordings: transcribed,
                player: player,
                onSeek: { rec, time in seek(rec, to: time) },
                onRenameCommit: { try? modelContext.save() }
            )
        }
    }

    // MARK: - Summary tab

    @ViewBuilder
    private var summaryTab: some View {
        if let summary = meeting.summary {
            VStack(alignment: .leading, spacing: 16) {
                SummaryView(summary: summary)
                generateButton(regenerate: true)
            }
        } else if txVM?.isSummarizing == true {
            VStack(spacing: 14) {
                ProgressView()
                Text(NSLocalizedString("detail.summarizing", comment: "Generating..."))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        } else if meeting.hasAnyTranscript {
            summaryEmptyState(canGenerate: true)
        } else {
            summaryEmptyState(canGenerate: false)
        }
    }

    private func summaryEmptyState(canGenerate: Bool) -> some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.fill)
                    .frame(width: 72, height: 72)
                Image(systemName: "sparkles").font(.system(size: 30)).foregroundStyle(Theme.textTertiary)
            }
            VStack(spacing: 8) {
                Text(NSLocalizedString("detail.summary.empty.title", comment: ""))
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text(NSLocalizedString("detail.summary.needs_transcript", comment: ""))
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Text("\(settings.aiProvider.displayName) · \(settings.summaryModel(for: settings.aiProvider))")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.fill, in: Capsule())

            if canGenerate { generateButton(regenerate: false) }
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private func generateButton(regenerate: Bool) -> some View {
        Button { generateSummary() } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                Text(regenerate
                     ? NSLocalizedString("detail.summary.regenerate", comment: "Regenerate")
                     : NSLocalizedString("detail.summary.generate", comment: "Generate Summary"))
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 54)
            .background(Theme.accent, in: Capsule())
            .shadow(color: Theme.accent.opacity(0.4), radius: 18, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(txVM?.isSummarizing == true)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.recordings, icon: "mic", label: NSLocalizedString("tab.recordings", comment: ""))
            tabButton(.transcript, icon: "text.alignleft", label: NSLocalizedString("tab.transcript", comment: ""))
            tabButton(.summary, icon: "sparkles", label: NSLocalizedString("tab.summary", comment: ""))
        }
        .padding(.top, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider().overlay(Theme.separator) }
    }

    private func tabButton(_ value: Tab, icon: String, label: String) -> some View {
        let active = tab == value
        return Button { tab = value } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 11, weight: active ? .semibold : .regular))
            }
            .foregroundStyle(active ? Theme.accent : Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .overlay(alignment: .top) {
                if active {
                    Capsule().fill(Theme.accent).frame(width: 20, height: 2.5)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }

    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textTertiary)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingEdit = true } label: {
                    Label(NSLocalizedString("common.edit", comment: "Edit"), systemImage: "pencil")
                }
                Button { share() } label: {
                    Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
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
        guard let txVM else { return }
        Task { await txVM.transcribe(recording, language: meeting.language, mode: mode) }
    }

    private func generateSummary() {
        guard let txVM else { return }
        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        Task { await txVM.generateSummary(for: meeting, provider: provider, model: model) }
    }

    private func deleteRecording(_ recording: Recording) {
        if player.loadedFileName == recording.fileName { player.stop() }
        AudioFileStore.delete(fileName: recording.fileName)
        modelContext.delete(recording)
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

/// Transcript tab content: speaker filter chips + speaker-attributed bubbles +
/// inline speaker renaming.
private struct TranscriptTab: View {
    let meeting: Meeting
    let recordings: [Recording]
    let player: AudioPlayerService
    let onSeek: (Recording, TimeInterval) -> Void
    let onRenameCommit: () -> Void

    @State private var selectedSpeaker: String?

    private var sortedSpeakers: [Speaker] { meeting.speakers.sorted { $0.label < $1.label } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !sortedSpeakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: NSLocalizedString("filter.all", comment: "All"),
                                   isSelected: selectedSpeaker == nil) { selectedSpeaker = nil }
                        ForEach(sortedSpeakers) { speaker in
                            FilterChip(
                                title: speaker.displayName,
                                isSelected: selectedSpeaker == speaker.label,
                                tint: Color(hex: speaker.color)
                            ) {
                                selectedSpeaker = (selectedSpeaker == speaker.label) ? nil : speaker.label
                            }
                        }
                    }
                }
            }

            ForEach(recordings) { recording in
                let segments = (recording.transcript?.segments ?? [])
                    .filter { selectedSpeaker == nil || $0.speakerLabel == selectedSpeaker }
                TranscriptView(
                    segments: segments,
                    speakers: meeting.speakers,
                    activeTime: player.loadedFileName == recording.fileName ? player.currentTime : nil,
                    onSeek: { time in onSeek(recording, time) }
                )
            }

            if !sortedSpeakers.isEmpty {
                Divider().overlay(Theme.separator).padding(.vertical, 4)
                Text(NSLocalizedString("detail.speakers", comment: "Speakers").uppercased())
                    .font(.system(size: 11, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                ForEach(sortedSpeakers) { speaker in
                    SpeakerRow(speaker: speaker, onCommit: onRenameCommit)
                }
                Text(NSLocalizedString("detail.speakers.note", comment: "Auto-detected note"))
                    .font(.footnote).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// Inline-editable speaker name with its color swatch.
private struct SpeakerRow: View {
    @Bindable var speaker: Speaker
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: speaker.color)).frame(width: 14, height: 14)
            TextField(speaker.label, text: $speaker.name).onSubmit(onCommit)
            Text(speaker.label).font(.caption2).foregroundStyle(Theme.textTertiary)
        }
        .meetsyncCard(padding: 12, cornerRadius: 12)
    }
}
