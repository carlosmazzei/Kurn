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

    @Environment(\.modelContext) var modelContext
    @Environment(AppSettings.self) var settings
    /// Shared, app-wide transcription coordinator (injected from `KurnApp`). Using
    /// the same instance the foreground resume pass uses means a run it restarted
    /// shows here as in-progress with live progress, instead of a stale badge.
    @Environment(TranscriptionViewModel.self) private var sharedTxVM

    enum Tab: Hashable { case recordings, transcript, summary }

    @State var player = AudioPlayerService()
    /// Optional passthrough so the existing `txVM?…` call sites stay unchanged.
    var txVM: TranscriptionViewModel? { sharedTxVM }
    @State private var tab: Tab = .recordings

    @State private var showingRecorder = false
    @State private var showingEdit = false
    @State var showingTemplatePicker = false
    @State var shareItem: ShareItem?
    @State var showingShareSelection = false
    /// Which of `meeting.summaries` is currently shown in the Summary tab.
    /// Falls back to the newest summary when nil or no longer present.
    @State var selectedSummaryID: UUID?
    /// Set when the user picks "Delete" on a summary chip; drives the
    /// confirmation dialog.
    @State var pendingDeleteSummary: Summary?
    /// Set when the user taps redo on a transcribed recording; drives the
    /// per-segment re-transcription confirmation dialog.
    @State private var pendingRetranscribe: Recording?
    /// Set when the user picks "Re-transcribe all" from the menu.
    @State private var pendingRetranscribeAll = false
    /// Set when auto-tagging is running.
    @State var isAutoTagging = false
    /// Auto-tagging suggestions awaiting confirmation.
    @State var autoTagSuggestion: AutoTaggingService.Suggestion?
    /// Auto-tagging failure surfaced to the user.
    @State var autoTagError: AppError?

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
        .onDisappear { player.stop() }
        .sheet(isPresented: $showingRecorder) {
            NavigationStack { RecorderView(meeting: meeting) }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack { MeetingFormView(meeting: meeting) }
        }
        .sheet(item: $shareItem) { item in ActivityView(items: item.urls) }
        .sheet(isPresented: $showingShareSelection) {
            MeetingShareSelectionView(meeting: meeting, preselectedSummary: selectedSummary) { urls in
                shareItem = ShareItem(urls: urls)
            }
        }
        .sheet(isPresented: $showingTemplatePicker) {
            SummaryTemplatePicker(
                templates: settings.summaryTemplates,
                selectedID: settings.lastSummaryTemplateID
            ) { template in
                runSummary(with: template)
            }
        }
        .errorAlert(Binding(get: { txVM?.error }, set: { txVM?.error = $0 }))
        .errorAlert($autoTagError)
        .sheet(item: $autoTagSuggestion) { suggestion in
            AutoTagConfirmView(
                meeting: meeting,
                suggestion: suggestion,
                onApply: { applyAutoTagSuggestion(suggestion) }
            )
        }
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
            isPresented: Binding(
                get: { pendingDeleteSummary != nil },
                set: { if !$0 { pendingDeleteSummary = nil } }
            ),
            iconSystemName: "trash.circle.fill",
            iconTint: Theme.warning,
            title: NSLocalizedString("detail.summary.delete_confirm.title", comment: "Delete summary confirmation"),
            message: NSLocalizedString("detail.summary.delete_confirm.message", comment: "Delete summary message"),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: {
                guard let summary = pendingDeleteSummary else { return }
                deleteSummary(summary)
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
        .kurnDialog(
            isPresented: $pendingRetranscribeAll,
            iconSystemName: "arrow.triangle.2.circlepath.circle.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("detail.retranscribe_all.confirm.title", comment: "Re-transcribe all confirmation"),
            message: NSLocalizedString("detail.retranscribe_all.confirm.message", comment: "Re-transcribe all message"),
            primaryTitle: NSLocalizedString("detail.retranscribe_all.confirm.action", comment: "Re-transcribe all confirm button"),
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
            if !meeting.tags.isEmpty {
                TagChipsView(tags: meeting.tags)
            }
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
                    isCancellingSummary: txVM?.isCancellingSummary == true,
                    summaryProgress: txVM?.summaryProgress,
                    selectedSummaryID: selectedSummaryID,
                    onGenerate: { generateSummary() },
                    onCancel: { cancelSummary() },
                    onSelectSummary: { selectedSummaryID = $0.id },
                    onDeleteSummary: { pendingDeleteSummary = $0 }
                )
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            }
            .onChange(of: meeting.summaries.count) { _, _ in
                selectedSummaryID = meeting.latestSummary?.id
            }
        }
    }

    // MARK: - Recordings tab (List, so swipe-to-delete works)

    private var recordingsList: some View {
        List {
            sectionLabel(NSLocalizedString("detail.recordings", comment: "Recordings"))
                .clearListRow(insets: EdgeInsets(top: 16, leading: 20, bottom: 4, trailing: 20))
            ForEach(Array(sortedRecordings.enumerated()), id: \.element.id) { index, recording in
                RecordingSegmentRow(
                    recording: recording,
                    index: index,
                    player: player,
                    txVM: txVM,
                    pendingRetranscribe: $pendingRetranscribe,
                    onTogglePlay: { togglePlay(recording) },
                    onCancelTranscription: { cancelTranscription(recording) },
                    onStopTranscription: { stopTranscription(recording) },
                    onStartTranscription: { startTranscription(recording) }
                )
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
                    onRenameCommit: { if let failure = modelContext.saveOrError() { txVM?.error = failure } }
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
            Button {
                meeting.isFavorite.toggle()
                if let failure = modelContext.saveOrError() { txVM?.error = failure }
            } label: {
                Image(systemName: meeting.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(meeting.isFavorite ? Theme.warning : Theme.textSecondary)
            }
            .accessibilityLabel(
                meeting.isFavorite
                    ? NSLocalizedString("meetings.unfavorite", comment: "Unfavorite")
                    : NSLocalizedString("meetings.favorite", comment: "Favorite")
            )
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingEdit = true } label: {
                    Label(NSLocalizedString("common.edit", comment: "Edit"), systemImage: "pencil")
                }
                Button { showingShareSelection = true } label: {
                    Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
                }
                Button {
                    meeting.archivedAt = meeting.isArchived ? nil : Date()
                    if let failure = modelContext.saveOrError() { txVM?.error = failure }
                } label: {
                    Label(
                        meeting.isArchived
                            ? NSLocalizedString("meetings.unarchive", comment: "Unarchive")
                            : NSLocalizedString("meetings.archive", comment: "Archive"),
                        systemImage: meeting.isArchived ? "tray.and.arrow.up" : "archivebox"
                    )
                }
                if meeting.hasAnyTranscript {
                    Button { pendingRetranscribeAll = true } label: {
                        Label(NSLocalizedString("detail.retranscribe_all", comment: "Re-transcribe all"), systemImage: "arrow.clockwise")
                    }
                }
                if settings.autoTaggingEnabled {
                    Button { suggestTags() } label: {
                        if isAutoTagging {
                            Label(NSLocalizedString("tag.auto_suggest", comment: "Suggest tags"), systemImage: "ellipsis")
                        } else {
                            Label(NSLocalizedString("tag.auto_suggest", comment: "Suggest tags"), systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isAutoTagging)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

private struct RecordingSegmentRow: View {
    let recording: Recording
    let index: Int
    let player: AudioPlayerService
    let txVM: TranscriptionViewModel?
    @Binding var pendingRetranscribe: Recording?
    let onTogglePlay: () -> Void
    let onCancelTranscription: () -> Void
    let onStopTranscription: () -> Void
    let onStartTranscription: () -> Void

    var body: some View {
        let isLoaded = player.loadedFileName == recording.fileName
        let isTranscribing = txVM?.isTranscribing(recording) == true
        let isCancelling = txVM?.isCancelling(recording) == true
        let phase = txVM?.phase(for: recording)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { onTogglePlay() } label: {
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
                    HStack(spacing: 8) {
                        if isCancelling {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                                .frame(width: 30, height: 30)
                        } else {
                            Button {
                                onCancelTranscription()
                            } label: {
                                Image(systemName: "pause.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 30, height: 30)
                                    .background(Theme.fill, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(NSLocalizedString("detail.cancel_transcription", comment: "Pause transcription"))
                            Button {
                                onStopTranscription()
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 30, height: 30)
                                    .background(Theme.fill, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(NSLocalizedString("detail.stop_transcription", comment: "Stop transcription"))
                        }
                    }
                } else if recording.transcriptionStatus == .pending {
                    // Interrupted mid-run with a checkpoint; tapping resumes
                    // right away instead of waiting for the next foreground pass.
                    Button {
                        onStartTranscription()
                    } label: {
                        StatusBadge(status: .pending)
                    }
                    .buttonStyle(.plain)
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
                } else if recording.transcriptionStatus == .failed {
                    // Show the real "Failed" state (not a mislabeled "Transcribe")
                    // with a retry that restarts — resuming from the checkpoint if
                    // the interrupted run left one.
                    HStack(spacing: 8) {
                        StatusBadge(status: .failed)
                        Button {
                            onStartTranscription()
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
                } else if recording.transcriptionStatus == .inProgress {
                    // Persisted `.inProgress` but not actually running in this
                    // process (a stale row awaiting the next recovery sweep, which
                    // moves it to `.pending` to resume or `.failed` to retry).
                    // Show the honest badge without a dead start button.
                    StatusBadge(status: .inProgress)
                } else {
                    Button {
                        onStartTranscription()
                    } label: {
                        StatusBadge(status: .none)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isTranscribing {
                transcriptionProgressBar(phase: phase, isCancelling: isCancelling)
                if let phase, !isCancelling {
                    Text(phase.displayName)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            // Show the scrubber whenever this recording is the loaded one — even
            // while transcription is still running, so playback started mid-
            // transcription still surfaces the slider and speed control.
            if isLoaded {
                SegmentPlaybackScrubber(
                    currentTime: player.currentTime,
                    duration: player.duration > 0 ? player.duration : recording.duration,
                    isPlaying: player.isPlaying,
                    playbackRate: player.playbackRate,
                    onSeek: { player.seek(to: $0) },
                    onCycleRate: { player.cycleRate() }
                )
            }
        }
        .kurnCard(padding: 14, cornerRadius: 16)
    }

    /// Thin bar shown beneath the row while a transcription is running.
    /// Indeterminate while cancelling — the Swift task waits for the concurrent
    /// diarization child task to finish before the catch block runs, so the last
    /// known fraction would be stale (stuck at e.g. 88%) for that entire window.
    @ViewBuilder
    private func transcriptionProgressBar(phase: TranscriptionPhase?, isCancelling: Bool) -> some View {
        if isCancelling {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Theme.accent.opacity(0.5))
        } else {
            let fraction = (phase ?? .preparing).fractionComplete
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .animation(.easeInOut(duration: 0.25), value: fraction)
        }
    }
}

private struct SegmentPlaybackScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let playbackRate: Float
    let onSeek: (TimeInterval) -> Void
    let onCycleRate: () -> Void

    private var playableDuration: TimeInterval { max(duration, 0) }
    private var sliderUpperBound: TimeInterval { max(playableDuration, 1) }
    private var boundedCurrentTime: TimeInterval {
        min(max(currentTime, 0), sliderUpperBound)
    }

    /// "1×", "1.5×", "0.5×" — `%g` drops trailing zeros and the decimal point.
    private var rateLabel: String {
        String(format: "%g×", playbackRate)
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
                Button(action: onCycleRate) {
                    Text(rateLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 34)
                        .padding(.vertical, 3)
                        .background(Theme.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("detail.playback_speed", comment: "Playback speed"))
                .accessibilityValue(rateLabel)
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
