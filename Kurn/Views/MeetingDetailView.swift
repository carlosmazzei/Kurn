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
    @State private var tab: Tab = .recordings

    @State private var showingRecorder = false
    /// Drives the full-screen photo viewer from the Recordings tab's photo
    /// strip — shown there independently of the Transcript tab's inline
    /// markers, which need transcript segments to anchor to and so stay
    /// empty until transcription finishes. Not `private` —
    /// `MeetingDetailPhotos.swift` needs it.
    @State var presentedPhoto: MeetingPhoto?
    /// Not `private` — `MeetingDetailToolbar.swift` needs it.
    @State var showingEdit = false
    /// Presents the generated article without adding a fifth item to the compact
    /// meeting section picker. The wiki is supporting material rather than a
    /// primary workflow, so it lives in the overflow menu. Not `private` —
    /// `MeetingDetailToolbar.swift` needs it.
    @State var showingWiki = false
    /// Opened from a transcription failure the large-transfer policy caused,
    /// so the cellular / Low Data Mode switches are one tap from the error.
    @State private var showingNetworkSettings = false
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
    /// Set when the user picks "Re-transcribe all" from the menu. Not
    /// `private` — `MeetingDetailToolbar.swift` needs it.
    @State var pendingRetranscribeAll = false
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
        // The Chat tab sits on the system background so the keyboard blends
        // with it (see `MeetingChatView`); the header follows so the two
        // don't meet in a visible seam at the divider.
        .background((tab == .chat ? Color(uiColor: .systemBackground) : Theme.background).ignoresSafeArea())
        .navigationTitle(meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .modelDownloadAlerts(downloads, settings: settings) { showingNetworkSettings = true }
        .onDisappear { player.stop() }
        .readAloudCoordination(player: player, meetingID: meeting.id, isRecording: showingRecorder)
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
        .sheet(item: $presentedPhoto) { photo in
            PhotoViewerView(photo: photo, onDelete: { deletePhoto(photo) })
        }
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
                    isSummarizing: summaries?.isSummarizing == true,
                    isCancellingSummary: summaries?.isCancellingSummary == true,
                    isTranslatingSummary: summaries?.isTranslatingSummary == true,
                    translationTargetLanguage: summaries?.translationTargetLanguage,
                    summaryProgress: summaries?.summaryProgress,
                    selectedSummaryID: selectedSummaryID,
                    hasAnyTranscript: hasAnyTranscript,
                    onGenerate: { generateSummary() },
                    onCancel: { cancelSummary() },
                    onSelectSummary: { selectedSummaryID = $0.id },
                    onDeleteSummary: { pendingDeleteSummary = $0 },
                    onTranslateSummary: { pendingTranslateSummary = $0 },
                    onCancelTranslateSummary: { cancelTranslateSummary() },
                    onShowPhoto: allPhotos.isEmpty ? nil : { showPhoto(atMeetingRelativeTime: $0) }
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
                    transcription: transcription,
                    enhancement: enhancement,
                    pendingRetranscribe: $pendingRetranscribe,
                    onTogglePlay: { togglePlay(recording) },
                    onToggleEnhancement: { toggleEnhancement(recording) },
                    onCancelTranscription: { cancelTranscription(recording) },
                    onStopTranscription: { stopTranscription(recording) },
                    onStartTranscription: { startTranscription(recording) },
                    onRetryCaptureRecovery: { retryCaptureRecovery(recording) }
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
            photosStrip
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

    /// Not `private` — `MeetingDetailPhotos.swift` needs it.
    func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.caption2Emphasized)
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }

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
