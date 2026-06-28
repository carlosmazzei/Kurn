//
//  MeetingDetailView.swift
//  Kurn
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
    @State private var showingTemplatePicker = false
    @State private var shareItem: ShareItem?
    /// Set when the user taps redo on a transcribed recording; drives the
    /// per-segment re-transcription confirmation dialog.
    @State private var pendingRetranscribe: Recording?
    /// Set when the user picks "Re-transcribe all" from the menu.
    @State private var pendingRetranscribeAll = false

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
        .sheet(isPresented: $showingTemplatePicker) {
            SummaryTemplatePicker(
                templates: settings.summaryTemplates,
                selectedID: settings.lastSummaryTemplateID
            ) { template in
                runSummary(with: template)
            }
        }
        .errorAlert(Binding(get: { txVM?.error }, set: { txVM?.error = $0 }))
        .kurnDialog(
            isPresented: Binding(
                get: { pendingRetranscribe != nil },
                set: { if !$0 { pendingRetranscribe = nil } }
            ),
            iconSystemName: "arrow.clockwise.circle.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("detail.retranscribe.confirm.title", comment: "Re-transcribe confirmation"),
            message: NSLocalizedString("detail.retranscribe.confirm.message", comment: "Re-transcribe message"),
            primaryTitle: NSLocalizedString("detail.retranscribe", comment: "Re-transcribe"),
            primaryRole: .destructive,
            primaryAction: {
                guard let recording = pendingRetranscribe else { return }
                retranscribe(recording)
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: $pendingRetranscribeAll,
            iconSystemName: "arrow.triangle.2.circlepath.circle.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("detail.retranscribe_all.confirm.title", comment: "Re-transcribe all confirmation"),
            message: NSLocalizedString("detail.retranscribe_all.confirm.message", comment: "Re-transcribe all message"),
            primaryTitle: NSLocalizedString("detail.retranscribe_all", comment: "Re-transcribe all"),
            primaryRole: .destructive,
            primaryAction: retranscribeAll,
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
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
                SummaryTab(
                    meeting: meeting,
                    settings: settings,
                    isSummarizing: txVM?.isSummarizing == true,
                    onGenerate: { generateSummary() }
                )
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
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
        let isTranscribing = txVM?.isTranscribing(recording) == true
        let phase = txVM?.phase(for: recording)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
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

                if isTranscribing {
                    // The phase label carries any known percentage via its
                    // `displayName`; the bar below mirrors it visually.
                    if let phase {
                        Text(phase.displayName)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                } else if recording.transcriptionStatus == .done {
                    HStack(spacing: 8) {
                        StatusBadge(status: .done)
                        Button {
                            pendingRetranscribe = recording
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 30, height: 30)
                                .background(Theme.fill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("detail.retranscribe", comment: "Re-transcribe"))
                    }
                } else {
                    Button {
                        startTranscription(recording)
                    } label: {
                        StatusBadge(status: .none)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isTranscribing {
                transcriptionProgressBar(phase: phase)
            } else if isLoaded {
                SegmentPlaybackScrubber(
                    currentTime: player.currentTime,
                    duration: player.duration > 0 ? player.duration : recording.duration,
                    isPlaying: player.isPlaying,
                    onSeek: { player.seek(to: $0) }
                )
            }
        }
        .kurnCard(padding: 14, cornerRadius: 16)
    }

    /// Thin bar shown beneath the row while a transcription is running.
    /// Always determinate: every stage maps to a forward-only band of
    /// `fractionComplete`, with the engine's real sub-progress filling the
    /// transcribing band. An indeterminate linear bar renders as a dead, empty
    /// line on iOS, so the user saw no movement during cleaning / detection.
    @ViewBuilder
    private func transcriptionProgressBar(phase: TranscriptionPhase?) -> some View {
        let fraction = (phase ?? .preparing).fractionComplete
        ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(Theme.accent)
            .animation(.easeInOut(duration: 0.25), value: fraction)
    }

    private struct SegmentPlaybackScrubber: View {
        let currentTime: TimeInterval
        let duration: TimeInterval
        let isPlaying: Bool
        let onSeek: (TimeInterval) -> Void

        private var playableDuration: TimeInterval { max(duration, 0) }
        private var sliderUpperBound: TimeInterval { max(playableDuration, 1) }
        private var boundedCurrentTime: TimeInterval {
            min(max(currentTime, 0), sliderUpperBound)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    let fraction = sliderUpperBound > 0 ? boundedCurrentTime / sliderUpperBound : 0
                    let markerWidth: CGFloat = 54
                    let markerX = min(
                        max(markerWidth / 2, proxy.size.width * fraction),
                        max(markerWidth / 2, proxy.size.width - markerWidth / 2)
                    )

                    Text(boundedCurrentTime.clockDisplay)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: markerWidth, height: 22)
                        .background(Theme.fill, in: Capsule())
                        .position(x: markerX, y: 11)
                }
                .frame(height: 24)

                Slider(
                    value: Binding(
                        get: { boundedCurrentTime },
                        set: { onSeek($0) }
                    ),
                    in: 0...sliderUpperBound
                )
                .tint(Theme.accent)
                .disabled(playableDuration <= 0)

                HStack(spacing: 8) {
                    Image(systemName: isPlaying ? "waveform" : "timer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("0:00")
                    Spacer(minLength: 8)
                    Text(playableDuration.clockDisplay)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(.leading, 46)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NSLocalizedString("detail.playback_position", comment: "Playback position"))
            .accessibilityValue("\(boundedCurrentTime.clockDisplay) / \(playableDuration.clockDisplay)")
        }
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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sortedRecordings, id: \.id) { recording in
                if let warning = txVM?.diarizationWarnings[recording.id] {
                    diarizationWarningBanner(warning)
                }
            }
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
    }

    private func diarizationWarningBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Theme.warning)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                if meeting.hasAnyTranscript {
                    Button { pendingRetranscribeAll = true } label: {
                        Label(NSLocalizedString("detail.retranscribe_all", comment: "Re-transcribe all"), systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

}

// MARK: - Actions & helpers
//
// Kept in a same-file extension so it stays out of the view's `type_body_length`
// budget while retaining access to the view's private state.

extension MeetingDetailView {

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

    private func startTranscription(_ recording: Recording) {
        guard let txVM else { return }
        Task {
            await txVM.transcribe(
                recording,
                language: meeting.language,
                config: settings.pipelineConfiguration
            )
        }
    }

    private func retranscribe(_ recording: Recording) {
        // `transcribe` replaces any existing transcript for this recording.
        startTranscription(recording)
    }

    private func retranscribeAll() {
        guard let txVM else { return }
        Task {
            await txVM.retranscribeAll(
                meeting,
                language: meeting.language,
                config: settings.pipelineConfiguration
            )
        }
    }

    private func generateSummary() {
        showingTemplatePicker = true
    }

    private func runSummary(with template: SummaryTemplate) {
        guard let txVM else { return }
        settings.lastSummaryTemplateID = template.id
        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        Task {
            await txVM.generateSummary(
                for: meeting,
                provider: provider,
                model: model,
                template: template
            )
        }
    }

    private func deleteRecording(_ recording: Recording) {
        if player.loadedFileName == recording.fileName { player.stop() }
        MeetingsViewModel(modelContext: modelContext).deleteRecording(recording)
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
