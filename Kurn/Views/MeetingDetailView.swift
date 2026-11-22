//
//  MeetingDetailView.swift
//  Kurn
//
//  The hub for one meeting, with Recordings / Transcript / Summary / Chat
//  and the independently enabled Knowledge mode. Recordings can be played and
//  transcribed; the transcript is speaker-filterable; the summary is generated
//  by the configured AI provider. Sharing exports a structured Markdown file.
//

import SwiftData
import KurnCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

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
    @Environment(TranscriptionCoordinator.self) private var sharedTranscription
    /// Shared summary generation/translation state, so a summary still
    /// running shows its progress when this screen is reopened.
    @Environment(SummaryViewModel.self) private var sharedSummaries
    /// Shared by all detail screens so a long enhancement remains observable
    /// across back-navigation instead of being orphaned with the old view.
    @Environment(PlaybackEnhancementViewModel.self) var enhancement
    /// Shared, app-wide wiki coordinator (injected from `KurnApp`), so the
    /// overflow menu's "Generate/Regenerate Wiki" reuses the same instance
    /// the post-transcription pipeline and Settings → Wiki already drive.
    @Environment(WikiCoordinator.self) var wiki
    /// The app-wide recording session "Add segment" starts (or re-opens, when
    /// a recording is already running minimized).
    @Environment(RecordingSessionController.self) private var recordingSession
    /// Per-meeting memory of the last chosen tab; optional so previews work.
    @Environment(MeetingDetailTabMemory.self) private var tabMemory: MeetingDetailTabMemory?
    /// Not `private` — `MeetingDetailDialogs.swift` pops the detail after
    /// the delete-meeting confirm.
    @Environment(\.dismiss) var dismiss

    typealias Tab = MeetingDetailMode

    @State var player = AudioPlayerService()
    /// Optional passthroughs, so a preview or test host without the
    /// environment objects renders instead of trapping.
    var transcription: TranscriptionCoordinator? { sharedTranscription }
    var summaries: SummaryViewModel? { sharedSummaries }
    /// This screen's own action failures (playback, delete, rename). Kept
    /// here rather than written into a shared coordinator's `error`, which
    /// would surface on whichever screen happens to observe it next. Not
    /// `private` — the `MeetingDetail*` extensions set it.
    @State var actionError: AppError?
    /// The first transcription failure among this meeting's own recordings
    /// (H9 PR 21) — `transcription` is one app-wide shared instance, so this screen
    /// must only ever surface an error that actually belongs to a recording
    /// it's showing, never a different meeting's background transcription
    /// failure. Dismissing clears just that recording's slot: if another of
    /// this meeting's recordings also has a queued failure, the next `get`
    /// picks it up automatically.
    private var transcriptionErrorBinding: Binding<AppError?> {
        Binding(
            get: {
                guard let transcription else { return nil }
                return queriedRecordings.lazy.compactMap { transcription.transcriptionError(for: $0) }.first
            },
            set: { newValue in
                guard newValue == nil, let transcription else { return }
                if let recording = queriedRecordings.first(where: { transcription.transcriptionError(for: $0) != nil }) {
                    transcription.clearTranscriptionError(for: recording)
                }
            }
        )
    }
    /// Not `private` — `MeetingDetailToolbar.swift` reads it for the menu.
    @State var tab: Tab = .summary
    @State private var tabInitialized = false
    @State var meetingKnowledge = MeetingKnowledgeViewModel()
    @State private var knowledgeRefresh = 0

    /// Drives the full-screen photo viewer from the Recordings tab's photo
    /// strip — shown there independently of the Transcript tab's inline
    /// markers, which need transcript segments to anchor to and so stay
    /// empty until transcription finishes. Not `private` —
    /// `MeetingDetailPhotos.swift` needs it.
    @State var presentedPhoto: MeetingPhoto?
    /// The Documents section's state. Not `private` —
    /// `MeetingDetailAttachments.swift` and the toolbar need it.
    @State var attachments = MeetingAttachmentsViewModel()
    /// Not `private` — `MeetingDetailToolbar.swift` needs it.
    @State var showingEdit = false
    /// Retains the article sheet shortcut alongside the opt-in inline content. Not `private` —
    /// `MeetingDetailToolbar.swift` needs it.
    @State var showingWiki = false
    /// Opened from a transcription failure the large-transfer policy caused,
    /// so the cellular / Low Data Mode switches are one tap from the error.
    /// Also the Transcript tab's "Transcription settings" link, so it is not
    /// `private` (`MeetingDetailTranscript.swift` sets it).
    @State var showingNetworkSettings = false
    @State var showingTemplatePicker = false
    @State var shareItem: ShareItem?
    @State var showingShareSelection = false
    /// Which of `meeting.summaries` is currently shown in the Summary tab.
    /// Falls back to the newest summary when nil or no longer present.
    @State var selectedSummaryID: UUID?
    /// Set when the user picks "Delete" on a summary chip; drives the
    /// confirmation dialog.
    @State var pendingDeleteSummary: Summary?
    /// Set when the user picks "Translate" on a summary chip; drives the
    /// target-language picker sheet.
    @State var pendingTranslateSummary: Summary?
    /// Set when the user taps redo on a transcribed recording; drives the
    /// per-segment re-transcription confirmation dialog.
    @State var pendingRetranscribe: Recording?
    /// Set from a recording row's actions menu, context menu or swipe action;
    /// drives the delete-recording confirmation dialog.
    @State var pendingDeleteRecording: Recording?
    /// Set when the user picks "Re-transcribe all" from the menu. Not
    /// `private` — `MeetingDetailToolbar.swift` needs it.
    @State var pendingRetranscribeAll = false
    /// Set when auto-tagging is running.
    @State var isAutoTagging = false
    /// Auto-tagging suggestions awaiting confirmation.
    @State var autoTagSuggestion: AutoTaggingService.Suggestion?
    /// Auto-tagging failure surfaced to the user.
    @State var autoTagError: AppError?
    /// The Ask sheet (`MeetingAskSheet`) — Ask is a sheet on every tab, not a
    /// tab of its own.
    @State private var showingAsk = false
    /// Drives the delete-meeting confirmation from the overflow menu.
    @State var pendingDeleteMeeting = false
    /// The tag and folder pickers from the overflow menu.
    @State var showingTagPicker = false
    @State var showingFolderPicker = false
    /// The "Compare side by side" summary sheet.
    @State private var showingCompare = false

    init(meeting: Meeting) {
        self.meeting = meeting
        let meetingID = meeting.id
        _queriedRecordings = Query(
            filter: #Predicate<Recording> { $0.meeting?.id == meetingID },
            sort: \Recording.recordedAt
        )
    }

    var body: some View {
        detailOverlays(base)
    }

    /// The screen itself — split from `detailOverlays` so neither half of
    /// the modifier chain is one giant expression for the type-checker
    /// (CI's slower compiler timed out here).
    private var base: some View {
        VStack(spacing: 0) {
            MeetingDetailHeader(meeting: meeting, expanded: tab == .summary, duration: totalDuration)
            sectionPicker
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            tabContent
        }
        // The summary/transcript/wiki tabs read on the white "paper" surface;
        // Audio sits on the app background like the list it is.
        .background((tab == .recordings ? Theme.background : Theme.readingBackground).ignoresSafeArea())
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            // While the summary is being read aloud, the floating read-aloud
            // bar takes over the Ask bar's spot — and it stays up after a
            // failure (phase idle + error) so the error text can be seen and
            // dismissed instead of vanishing with the bar.
            if let item = readAloudItem,
               ReadAloudController.shared.phase(for: item.id) != .idle
                 || ReadAloudController.shared.error(for: item.id) != nil {
                ReadAloudBar(item: item)
            } else {
                MeetingAskBar { showingAsk = true }
            }
        }
        .sheet(isPresented: $showingAsk) {
            MeetingAskSheet(meeting: meeting) { time in
                jumpToTime(time)
            }
        }
        .sheet(isPresented: $showingTagPicker) {
            TagPickerView(meeting: meeting)
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPickerView(meeting: meeting)
        }
        .sheet(isPresented: $showingCompare) {
            SummaryCompareView(
                summaries: meeting.summaries.sorted { $0.createdAt > $1.createdAt },
                currentID: selectedSummary?.id,
                meeting: meeting
            )
        }
        .onAppear(perform: applyInitialTab)
        .onChange(of: tab) { _, newTab in
            tabMemory?.set(newTab, for: meeting.id)
        }
        // Lets an outside actor (the meetings list, after a recording saved
        // into this meeting) flip the tab live: the memory is the only
        // channel reaching a detail already on screen. `tab`'s own onChange
        // writes the same value back, so this never loops.
        .onChange(of: tabMemory?.tab(for: meeting.id)) { _, remembered in
            if let remembered, remembered != tab,
               Tab.visible(knowledgeEnabled: settings.knowledgeEnabled).contains(remembered) {
                tab = remembered
            }
        }
        .background {
            if settings.knowledgeEnabled {
                MeetingKnowledgeRefreshDriver(meetingID: meeting.id, model: meetingKnowledge, refreshID: knowledgeRefresh)
            }
        }
        .onChange(of: settings.knowledgeEnabled) { _, enabled in
            meetingKnowledge.invalidate()
            if !enabled, tab == .knowledge { tab = .summary }
        }
        .toolbar { toolbarContent }
        .modelDownloadAlerts(downloads, settings: settings) { showingNetworkSettings = true }
    }

    /// Sheets, alerts and confirmation dialogs layered over `base` — the
    /// second half of the split that keeps `body` under the CI type-check
    /// budget.
    private func detailOverlays(_ content: some View) -> some View {
        content
            .onDisappear { player.stop(); meetingKnowledge.invalidate() }
            .readAloudCoordination(player: player, meetingID: meeting.id, isRecording: recordingSession.isActive)
            .errorAlert(Binding(get: { enhancement.error }, set: { enhancement.error = $0 }))
            .sheet(isPresented: $showingEdit) {
                NavigationStack { MeetingFormView(meeting: meeting) }
            }
            .sheet(isPresented: $showingWiki) {
                if let article = meeting.wikiArticle {
                    NavigationStack { MeetingWikiView(article: article) }
                }
            }
            .sheet(item: $shareItem) { item in ActivityView(items: item.urls) }
            .sheet(item: $presentedPhoto) { photo in
                PhotoViewerView(photo: photo, onDelete: { deletePhoto(photo) })
            }
            .fileImporter(
                isPresented: $attachments.isShowingImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                Task { await attachments.importPicked(result, into: meeting, context: modelContext) }
            }
            .quickLookPreview($attachments.previewURL)
            .errorAlert($attachments.error)
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
            .sheet(item: $pendingTranslateSummary) { summary in
                SummaryTranslateLanguagePicker(
                    suggestedLanguage: meeting.transcribedLanguage ?? meeting.language
                ) { language in
                    runTranslateSummary(summary, to: language)
                }
            }
            .errorAlert(transcriptionErrorBinding, onOpenNetworkSettings: { showingNetworkSettings = true })
            .sheet(isPresented: $showingNetworkSettings) {
                NavigationStack {
                    TranscriptionSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(NSLocalizedString("common.done", comment: "Done")) {
                                    showingNetworkSettings = false
                                }
                            }
                        }
                }
            }
            .errorAlert($autoTagError)
            .errorAlert(Binding(get: { wiki.lastError }, set: { wiki.lastError = $0 }))
            .errorAlert($actionError)
            .errorAlert(Binding(get: { summaries?.error }, set: { summaries?.error = $0 }))
            .errorAlert(Binding(get: { transcription?.error }, set: { transcription?.error = $0 }))
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
            .detailRetranscribeDialog(pending: $pendingRetranscribe) { retranscribe($0) }
            .detailDeleteSummaryDialog(pending: $pendingDeleteSummary) { deleteSummary($0) }
            .detailDeleteMeetingDialog(
                isPresented: $pendingDeleteMeeting,
                meetingTitle: meeting.title,
                onConfirm: deleteMeetingAndDismiss
            )
            .recordingDeleteDialog(pending: $pendingDeleteRecording) { deleteRecording($0) }
            .attachmentDeleteDialog(attachments: attachments, modelContext: modelContext)
            .detailRetranscribeAllDialog(isPresented: $pendingRetranscribeAll, onConfirm: retranscribeAll)
    }

    /// First-open tab choice: the remembered one when this meeting was
    /// visited before (and it's still visible), else summary → transcript →
    /// recordings by available content.
    private func applyInitialTab() {
        guard !tabInitialized else { return }
        tabInitialized = true
        let visible = Tab.visible(knowledgeEnabled: settings.knowledgeEnabled)
        if let remembered = tabMemory?.tab(for: meeting.id), visible.contains(remembered) {
            tab = remembered
        } else if meeting.latestSummary != nil {
            tab = .summary
        } else if hasAnyTranscript {
            tab = .transcript
        } else {
            tab = .recordings
        }
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
                    isSummarizing: summaries?.isSummarizing == true,
                    isTranslatingSummary: summaries?.isTranslatingSummary == true,
                    translationTargetLanguage: summaries?.translationTargetLanguage,
                    summaryProgress: summaries?.summaryProgress,
                    summaryWordsReceived: summaries?.summaryWordsReceived,
                    summaryDraft: summaries?.summaryDraft ?? "",
                    summaryRequestStartedAt: summaries?.summaryRequestStartedAt,
                    selectedSummaryID: selectedSummaryID,
                    hasAnyTranscript: hasAnyTranscript,
                    onGenerate: { generateSummary() },
                    onCancel: { cancelSummary() },
                    onSelectSummary: { selectedSummaryID = $0.id },
                    onDeleteSummary: { pendingDeleteSummary = $0 },
                    onTranslateSummary: { pendingTranslateSummary = $0 },
                    onCancelTranslateSummary: { cancelTranslateSummary() },
                    onCompare: { showingCompare = true },
                    onShare: { showingShareSelection = true },
                    onCopySummary: { MeetingPasteboard.copy(SummaryService.markdownText(from: $0.sections)) },
                    onShowPhoto: allPhotos.isEmpty ? nil : { showPhoto(atMeetingRelativeTime: $0) }
                )
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            }
            .onChange(of: meeting.summaries.count) { _, _ in
                selectedSummaryID = meeting.latestSummary?.id
            }
        case .knowledge:
            if settings.knowledgeEnabled {
                MeetingKnowledgeView(meeting: meeting, state: meetingKnowledge.presentation(for: meeting.id),
                    headerText: meetingKnowledge.header(for: meeting.id),
                    isGeneratingArticle: isGeneratingWiki,
                    canGenerateArticle: canGenerateWiki, generatesLocally: settings.aiProvider.kind == .appleOnDevice, onRefresh: {
                        meetingKnowledge.invalidate()
                        knowledgeRefresh += 1
                    })
            }
        }
    }

    /// Tap on a `[m:ss]` cited in a chat answer: find the recording
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

    // MARK: - Audio tab (grouped list on the app background)

    private var recordingsList: some View {
        List {
            Section {
                ForEach(Array(sortedRecordings.enumerated()), id: \.element.id) { index, recording in
                    RecordingSegmentRow(
                        recording: recording,
                        index: index,
                        player: player,
                        transcription: transcription,
                        enhancement: enhancement,
                        pendingRetranscribe: $pendingRetranscribe,
                        onTogglePlay: { togglePlay(recording) },
                        onToggleEnhancement: { toggleEnhancement(recording) },
                        onCancelTranscription: { cancelTranscription(recording) },
                        onStopTranscription: { stopTranscription(recording) },
                        onStartTranscription: { startTranscription(recording) },
                        onRetryCaptureRecovery: { retryCaptureRecovery(recording) },
                        onRequestDelete: { pendingDeleteRecording = recording }
                    )
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDeleteRecording = recording } label: {
                            Label(NSLocalizedString("common.delete", comment: "Delete"), systemImage: "trash")
                        }
                    }
                }
                addRecordingRow
            } header: {
                Text(NSLocalizedString("detail.recordings", comment: "Recordings"))
            }

            if let loaded = loadedRecording {
                Section {
                    playerCard(loaded)
                }
            }

            photosSection
            attachmentsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .listRowBackground(Theme.surface)
    }

    /// The recording currently loaded into `player`, if any — drives the
    /// grouped player card under the Recordings section.
    private var loadedRecording: Recording? {
        guard let fileName = player.loadedFileName else { return nil }
        return sortedRecordings.first { $0.fileName == fileName }
    }

    /// Elapsed/remaining, the scrub slider and the transport row for the
    /// recording being played — playback logic stays in `player`.
    private func playerCard(_ recording: Recording) -> some View {
        SegmentPlaybackScrubber(
            currentTime: player.currentTime,
            duration: player.duration > 0 ? player.duration : recording.duration,
            isPlaying: player.isPlaying,
            playbackRate: player.playbackRate,
            isEnhanced: player.isPlayingEnhanced,
            enhancementProgress: enhancement.progress(for: recording),
            onSeek: { player.seek(to: $0) },
            onSkip: { player.skip(by: $0) },
            onTogglePlay: { togglePlay(recording) },
            onCycleRate: { player.cycleRate() },
            onToggleEnhancement: { toggleEnhancement(recording) }
        )
    }

    /// Last row of the Recordings group: starts a new segment, or — while a
    /// recording runs minimized — says so and re-opens it, since a second
    /// capture cannot start alongside it.
    private var addRecordingRow: some View {
        Button { recordingSession.begin(meeting: meeting) } label: {
            HStack(spacing: 8) {
                Image(systemName: recordingSession.isActive ? "waveform" : "plus")
                    .foregroundStyle(recordingSession.isActive ? Theme.record : Theme.link)
                    .accessibilityHidden(true)
                Text(addSegmentTitle)
                    .font(Theme.body)
                    .foregroundStyle(recordingSession.isActive ? Theme.record : Theme.link)
                Spacer()
            }
        }
        .accessibilityHint(recordingSession.isActive
            ? NSLocalizedString("recorder.mini.hint", comment: "Opens the full recorder")
            : "")
    }

    private var addSegmentTitle: String {
        if recordingSession.isRecording(into: meeting) {
            return NSLocalizedString("detail.recording_in_progress", comment: "Recording in progress")
        }
        if recordingSession.isActive {
            return NSLocalizedString("detail.open_active_recording", comment: "Another meeting is being recorded; opens it")
        }
        return NSLocalizedString("detail.recording.add", comment: "Add recording")
    }

    // MARK: - Section picker

    /// These are view modes of one meeting, not top-level
    /// destinations, so they get a segmented control rather than a bottom bar —
    /// which leaves the bottom edge free for the floating Ask bar.
    private var sectionPicker: some View {
        Picker(NSLocalizedString("detail.section", comment: "Meeting section"), selection: $tab) {
            ForEach(Tab.visible(knowledgeEnabled: settings.knowledgeEnabled), id: \.self) { value in
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

    func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(title).font(.headline).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}
