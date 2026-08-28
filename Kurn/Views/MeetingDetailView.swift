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
import KurnCore
import SwiftUI

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    /// Scoped to this meeting so the recordings list refreshes on every
    /// context save — see `sortedRecordings` in `MeetingDetailActions.swift`
    /// for why `meeting.recordings` itself isn't used.
    @Query var queriedRecordings: [Recording]

    @Environment(\.modelContext) var modelContext
    @Environment(AppSettings.self) var settings
    /// Only for the diarization-model prompt in the transcript's warning banner.
    @Environment(ModelDownloadController.self) var downloads
    /// Shared, app-wide transcription coordinator (injected from `KurnApp`). Using
    /// the same instance the foreground resume pass uses means a run it restarted
    /// shows here as in-progress with live progress, instead of a stale badge.
    @Environment(TranscriptionViewModel.self) private var sharedTxVM
    /// Shared by all detail screens so a long enhancement remains observable
    /// across back-navigation instead of being orphaned with the old view.
    @Environment(PlaybackEnhancementViewModel.self) var enhancement

    enum Tab: Hashable, CaseIterable {
        case recordings, transcript, summary, chat

        var systemImage: String {
            switch self {
            case .recordings: return "mic"
            case .transcript: return "text.alignleft"
            case .summary: return "sparkles"
            case .chat: return "bubble.left.and.text.bubble.right"
            }
        }

        var title: String {
            switch self {
            case .recordings: return NSLocalizedString("tab.recordings", comment: "Recordings tab")
            case .transcript: return NSLocalizedString("tab.transcript", comment: "Transcript tab")
            case .summary: return NSLocalizedString("tab.summary", comment: "Summary tab")
            case .chat: return NSLocalizedString("tab.chat", comment: "Chat tab")
            }
        }
    }

    @State var player = AudioPlayerService()
    /// Optional passthrough so the existing `txVM?…` call sites stay unchanged.
    var txVM: TranscriptionViewModel? { sharedTxVM }
    @State private var tab: Tab = .recordings

    @State private var showingRecorder = false
    @State private var showingEdit = false
    /// Presents the generated article without adding a fifth item to the compact
    /// meeting section picker. The wiki is supporting material rather than a
    /// primary workflow, so it lives in the overflow menu.
    @State private var showingWiki = false
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

    init(meeting: Meeting) {
        self.meeting = meeting
        let meetingID = meeting.id
        _queriedRecordings = Query(
            filter: #Predicate<Recording> { $0.meeting?.id == meetingID },
            sort: \Recording.recordedAt
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionPicker
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Divider().overlay(Theme.separator)
            tabContent
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .modelDownloadAlerts(downloads, settings: settings)
        .onDisappear { player.stop() }
        .errorAlert(Binding(get: { enhancement.error }, set: { enhancement.error = $0 }))
        .sheet(isPresented: $showingRecorder) {
            NavigationStack { RecorderView(meeting: meeting) }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack { MeetingFormView(meeting: meeting) }
        }
        .sheet(isPresented: $showingWiki) {
            if let article = meeting.wikiArticle {
                NavigationStack { MeetingWikiView(article: article) }
            }
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
                onApply: { selectedSuggestion in
                    applyAutoTagSuggestion(selectedSuggestion)
                }
            )
        }
        .sheet(item: crossMeetingMatchBinding, content: crossMeetingMatchSheetContent)
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
        // The real transcribed language once one exists; otherwise the
        // pre-transcription hint (Settings default or per-meeting override),
        // so this always shows something and quietly upgrades once
        // transcription lands on the language that actually counts.
        let displayLanguage = meeting.transcribedLanguage ?? meeting.language
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(meeting.createdAt.meetingDisplay)
                metaDot
                Text(String(format: NSLocalizedString("detail.segment_count", comment: ""), sortedRecordings.count))
                if totalDuration > 0 {
                    metaDot
                    Text(totalDuration.clockDisplay)
                }
            }
            .font(Theme.footnote)
            .foregroundStyle(Theme.textSecondary)
            Text(displayLanguage.displayName)
                .font(Theme.footnote)
                .foregroundStyle(Theme.textSecondary)
            if !meeting.tags.isEmpty {
                TagChipsView(tags: meeting.tags)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 12)
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
                    hasAnyTranscript: hasAnyTranscript,
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
        case .chat:
            MeetingChatView(meeting: meeting, onJump: jumpToCitation, onJumpToTime: jumpToTime)
        }
    }

    /// Citation tap in the Chat tab: switch to the transcript and seek the
    /// source recording to the cited moment (converting the absolute meeting
    /// timestamp back to recording-relative time).
    private func jumpToCitation(_ hit: SemanticSearchService.Hit) {
        guard let recording = sortedRecordings.first(where: { $0.id == hit.recordingID }) else { return }
        tab = .transcript
        seek(recording, to: max(0, hit.start - startOffset(of: recording)))
    }

    /// Tap on a `[mm:ss]` cited in a full-context answer: find the recording
    /// whose span contains that absolute meeting time and seek into it.
    private func jumpToTime(_ absolute: TimeInterval) {
        for recording in sortedRecordings {
            let offset = startOffset(of: recording)
            if absolute >= offset && absolute <= offset + recording.duration {
                tab = .transcript
                seek(recording, to: max(0, absolute - offset))
                return
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
                    enhancement: enhancement,
                    pendingRetranscribe: $pendingRetranscribe,
                    onTogglePlay: { togglePlay(recording) },
                    onToggleEnhancement: { toggleEnhancement(recording) },
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
                    Image(systemName: "plus").font(.system(.footnote, design: .default, weight: .bold)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
                Text(NSLocalizedString("detail.add_segment", comment: "Add segment"))
                    .font(Theme.subheadline).foregroundStyle(Theme.textSecondary)
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
        let transcribed = sortedRecordings.filter { $0.transcript?.segments.isEmpty == false }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sortedRecordings, id: \.id) { recording in
                if let warning = txVM?.diarizationWarnings[recording.id] {
                    diarizationWarningBanner(warning)
                }
            }
            if transcribed.isEmpty {
                transcriptEmptyPlaceholder
            } else {
                TranscriptTab(
                    meeting: meeting,
                    recordings: transcribed,
                    player: player,
                    offsetFor: { startOffset(of: $0) },
                    onSeek: { rec, time in seek(rec, to: time) },
                    onRenameCommit: { if let failure = modelContext.saveOrError() { txVM?.error = failure } }
                )
            }
        }
    }

    /// Which empty-state copy to show when no recording has a real (non-empty)
    /// transcript: distinguishes "never attempted", "failed" (so a stale or
    /// zero-segment transcript from a previous run never leaves the tab stuck
    /// blank instead of reverting here), and "done but no speech detected" (a
    /// legitimately silent recording, not a failure).
    @ViewBuilder
    private var transcriptEmptyPlaceholder: some View {
        if sortedRecordings.contains(where: { $0.transcriptionStatus == .failed }) {
            placeholder(
                icon: "exclamationmark.triangle",
                title: NSLocalizedString("detail.transcript.failed.title", comment: ""),
                subtitle: NSLocalizedString("detail.transcript.failed.subtitle", comment: "")
            )
        } else if sortedRecordings.contains(where: { $0.transcriptionStatus == .done && $0.transcript?.segments.isEmpty != false }) {
            placeholder(
                icon: "waveform.slash",
                title: NSLocalizedString("detail.transcript.no_speech.title", comment: ""),
                subtitle: NSLocalizedString("detail.transcript.no_speech.subtitle", comment: "")
            )
        } else {
            placeholder(
                icon: "text.alignleft",
                title: NSLocalizedString("detail.transcript.empty.title", comment: ""),
                subtitle: NSLocalizedString("detail.transcript.empty.subtitle", comment: "")
            )
        }
    }

    private func diarizationWarningBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(Theme.warning)
            // The consent prompt lives here, not only in Settings. The neural
            // diarizer is the default, but it cannot download itself, and a user
            // who never opens Settings would silently keep the fallback engine
            // forever — the new default would reach nobody. This is the one
            // moment they can see the difference it would make.
            if settings.diarizationEngine == .fluidAudio,
               !settings.fluidAudioDiarizationModelsConsented {
                Button {
                    downloads.selectDiarizationEngine(.fluidAudio, settings: settings)
                } label: {
                    Text(NSLocalizedString(
                        "detail.download_diarization_models",
                        comment: "Download the speaker separation models"
                    ))
                    .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(downloads.isDownloading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Section picker

    /// The four sections are view modes of one meeting, not top-level
    /// destinations, so they get a segmented control rather than a bottom bar —
    /// which also leaves the bottom edge free for the Chat tab's composer.
    private var sectionPicker: some View {
        Picker(NSLocalizedString("detail.section", comment: "Meeting section"), selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { value in
                Image(systemName: value.systemImage)
                    .accessibilityLabel(value.title)
                    .accessibilityIdentifier("tab.\(value)")
                    .tag(value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.caption2Emphasized)
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }

    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
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
        // Keeps the favorite toggle in a glass group of its own, separate from
        // the overflow menu.
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { showingEdit = true } label: {
                    Label(NSLocalizedString("common.edit", comment: "Edit"), systemImage: "pencil")
                }
                Button { showingShareSelection = true } label: {
                    Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
                }
                if meeting.wikiArticle != nil {
                    Button { showingWiki = true } label: {
                        Label(
                            NSLocalizedString("detail.wiki.view", comment: "View meeting wiki"),
                            systemImage: "book.pages"
                        )
                    }
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
                if hasAnyTranscript {
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
            .accessibilityLabel(NSLocalizedString("detail.more_options", comment: "More options"))
        }
    }
}

private struct RecordingSegmentRow: View {
    let recording: Recording
    let index: Int
    let player: AudioPlayerService
    let txVM: TranscriptionViewModel?
    let enhancement: PlaybackEnhancementViewModel
    @Binding var pendingRetranscribe: Recording?
    let onTogglePlay: () -> Void
    let onToggleEnhancement: () -> Void
    let onCancelTranscription: () -> Void
    let onStopTranscription: () -> Void
    let onStartTranscription: () -> Void

    var body: some View {
        let isLoaded = player.loadedFileName == recording.fileName
        let isTranscribing = txVM?.isTranscribing(recording) == true
        let isCancelling = txVM?.isCancelling(recording) == true
        let phase = txVM?.phase(for: recording)
        let postTranscriptionPhase = txVM?.postTranscriptionPhase(for: recording)
        let enhancementProgress = enhancement.progress(for: recording)
        let isEnhancing = enhancementProgress != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { onTogglePlay() } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.fill)
                            .frame(width: 34, height: 34)
                        if isEnhancing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        } else {
                            Image(systemName: (isLoaded && player.isPlaying) ? "pause.fill" : "play.fill")
                                .font(Theme.footnote)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isEnhancing)
                .accessibilityLabel(
                    isEnhancing
                        ? NSLocalizedString("detail.enhancing_audio", comment: "Enhancing audio")
                        : ((isLoaded && player.isPlaying)
                            ? NSLocalizedString("detail.pause_recording", comment: "Pause recording")
                            : NSLocalizedString("detail.play_recording", comment: "Play recording"))
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: NSLocalizedString("detail.recording_n", comment: ""), index + 1))
                        .font(Theme.subheadlineEmphasized)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(recording.recordedAt.meetingDisplay) · \(recording.duration.clockDisplay)")
                        .font(Theme.caption)
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
                                    .font(Theme.footnoteEmphasized)
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
                                    .font(Theme.footnoteEmphasized)
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
                                .font(Theme.footnoteEmphasized)
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
                                .font(Theme.footnoteEmphasized)
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
            } else if let postTranscriptionPhase {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Text(postTranscriptionPhase.displayName)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            if !isLoaded, let enhancementProgress {
                EnhancementProgressView(progress: enhancementProgress)
                    .padding(.leading, 46)
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
                    isEnhanced: player.isPlayingEnhanced,
                    enhancementProgress: enhancementProgress,
                    onSeek: { player.seek(to: $0) },
                    onSkip: { player.skip(by: $0) },
                    onCycleRate: { player.cycleRate() },
                    onToggleEnhancement: onToggleEnhancement
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
        } else if case .some(.diarizing(progress: nil)) = phase {
            // Keep a truthful fallback for diarizers that cannot report a
            // fraction instead of leaving transcription parked at 100%.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Theme.accent)
        } else {
            let fraction = (phase ?? .preparing).fractionComplete
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .kurnAnimation(.easeInOut(duration: 0.25), value: fraction)
        }
    }
}

private struct SegmentPlaybackScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let playbackRate: Float
    let isEnhanced: Bool
    let enhancementProgress: Double?
    let onSeek: (TimeInterval) -> Void
    let onSkip: (TimeInterval) -> Void
    let onCycleRate: () -> Void
    let onToggleEnhancement: () -> Void

    private var playableDuration: TimeInterval { max(duration, 0) }
    private var sliderUpperBound: TimeInterval { max(playableDuration, 1) }
    private var boundedCurrentTime: TimeInterval {
        min(max(currentTime, 0), sliderUpperBound)
    }
    private var isEnhancing: Bool { enhancementProgress != nil }

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
                    .font(Theme.caption2Emphasized)
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
            // VoiceOver's Adjustable rotor acts on the slider itself, so it
            // needs its own label/value — the container's `.contain` grouping
            // below keeps this reachable but doesn't supply them on its own.
            .accessibilityLabel(NSLocalizedString("detail.playback_position", comment: "Playback position"))
            .accessibilityValue("\(boundedCurrentTime.clockDisplay) / \(playableDuration.clockDisplay)")

            HStack(spacing: 8) {
                Image(systemName: isPlaying ? "waveform" : "timer")
                    .font(Theme.caption2Emphasized)
                    .foregroundStyle(Theme.textTertiary)
                Text("0:00")
                Spacer(minLength: 8)
                Button { onSkip(-AudioPlayerService.skipInterval) } label: {
                    Image(systemName: "gobackward.15")
                        .font(Theme.captionEmphasized)
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 34)
                        .padding(.vertical, 3)
                        .background(Theme.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("detail.skip_backward", comment: "Skip back 15 seconds"))
                Button { onSkip(AudioPlayerService.skipInterval) } label: {
                    Image(systemName: "goforward.15")
                        .font(Theme.captionEmphasized)
                        .foregroundStyle(Theme.accent)
                        .frame(minWidth: 34)
                        .padding(.vertical, 3)
                        .background(Theme.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("detail.skip_forward", comment: "Skip forward 15 seconds"))
                Button(action: onToggleEnhancement) {
                    Group {
                        if isEnhancing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.5)
                        } else {
                            Image(systemName: "sparkles")
                                .font(Theme.caption2Emphasized)
                                .foregroundStyle(isEnhanced ? Theme.accent : Theme.textTertiary)
                        }
                    }
                    .frame(minWidth: 34)
                    .padding(.vertical, 3)
                    .background(Theme.fill, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isEnhancing)
                .accessibilityLabel(NSLocalizedString("detail.playback_enhancement", comment: "Enhanced audio"))
                .accessibilityValue(
                    isEnhancing
                        ? NSLocalizedString("detail.enhancing_audio", comment: "Enhancing audio")
                        : (isEnhanced
                            ? NSLocalizedString("common.on", comment: "On")
                            : NSLocalizedString("common.off", comment: "Off"))
                )
                Button(action: onCycleRate) {
                    Text(rateLabel)
                        .font(Theme.caption2Emphasized)
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
            .font(Theme.caption2)
            .foregroundStyle(Theme.textTertiary)

            if let enhancementProgress {
                EnhancementProgressView(progress: enhancementProgress)
            }
        }
        .padding(.leading, 46)
        // `.contain` rather than `.combine`: combining flattens the children into
        // one element, which makes the speed and enhancement buttons unreachable
        // to VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("detail.playback_position", comment: "Playback position"))
        .accessibilityValue("\(boundedCurrentTime.clockDisplay) / \(playableDuration.clockDisplay)")
    }
}
