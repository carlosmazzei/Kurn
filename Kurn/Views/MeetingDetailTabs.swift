//
//  MeetingDetailTabs.swift
//  Kurn
//
//  Tab content split out of `MeetingDetailView` to keep that file under
//  SwiftLint's length limits: the speaker-attributed transcript tab (with inline
//  speaker renaming) and the AI summary tab.
//

import KurnCore
import SwiftUI

/// Transcript tab content: speaker filter chips + speaker-attributed bubbles +
/// inline speaker renaming.
struct TranscriptTab: View {
    let meeting: Meeting
    let recordings: [Recording]
    let player: AudioPlayerService
    /// Computed by the parent from the meeting's *full* recordings list (not
    /// just `recordings` above, which is filtered to transcribed segments) —
    /// the offset accounts for every earlier recording, transcribed or not.
    let offsetFor: (Recording) -> TimeInterval
    let onSeek: (Recording, TimeInterval) -> Void
    let onRenameCommit: () -> Void
    var onDeletePhoto: ((MeetingPhoto) -> Void)?

    @State private var selectedSpeaker: String?
    @State private var presentedPhoto: MeetingPhoto?

    /// Labels that actually say something in the transcripts on screen.
    ///
    /// `meeting.speakers` can outlive them: a row the user has named is kept
    /// when a re-transcription stops producing its label, because deleting it
    /// would throw away what they typed (see `syncSpeakers`). Keeping it is the
    /// right call for the data and the wrong one for this view — it would render
    /// as a chip that filters to nothing and a row in a list of people who are
    /// not in the transcript.
    private var spokenLabels: Set<String> {
        var labels: Set<String> = []
        for recording in recordings {
            for segment in recording.transcript?.segments ?? [] {
                labels.insert(segment.speakerLabel)
            }
        }
        return labels
    }

    private var sortedSpeakers: [Speaker] {
        let spoken = spokenLabels
        return meeting.speakers
            .filter { spoken.contains($0.label) }
            .sorted { $0.label < $1.label }
    }

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
                    offset: offsetFor(recording),
                    highlights: recording.highlights,
                    photos: recording.photos,
                    onSeek: { time in onSeek(recording, time) },
                    onShowPhoto: { presentedPhoto = $0 }
                )
            }

            if !sortedSpeakers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("detail.participants", comment: "Participants").uppercased())
                        .font(Theme.caption2Emphasized).tracking(0.8)
                        .foregroundStyle(Theme.textTertiary)
                    VStack(spacing: 0) {
                        ForEach(Array(sortedSpeakers.enumerated()), id: \.element.id) { index, speaker in
                            SpeakerRow(speaker: speaker, onCommit: onRenameCommit)
                            if index < sortedSpeakers.count - 1 {
                                Divider().overlay(Theme.separator)
                                    .padding(.leading, 44)
                            }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    Text(NSLocalizedString("detail.speakers.note", comment: "Auto-detected note"))
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, 8)
            }
        }
        .sheet(item: $presentedPhoto) { photo in
            PhotoViewerView(photo: photo, onDelete: onDeletePhoto == nil ? nil : { onDeletePhoto?(photo) })
        }
    }
}

/// Inline-editable speaker name with its color avatar, inside the grouped
/// Participants container (separators are drawn by the parent).
private struct SpeakerRow: View {
    @Bindable var speaker: Speaker
    let onCommit: () -> Void

    var body: some View {
        let color = Color(hex: speaker.color)
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 22, height: 22)
                Text(String(speaker.displayName.prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
            }
            .accessibilityHidden(true)
            TextField(speaker.label, text: $speaker.name).onSubmit(onCommit)
            Text(speaker.label).font(.caption2).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Summary tab content: a switcher across every generated summary (when more
/// than one exists), the selected summary's body, and a button to generate
/// another one (or an empty state when none exist yet).
/// Summary tab content: the summary bar (pill menu + Listen + page dots), the
/// selected summary rendered on paper, a discreet streaming state while a
/// summary is being written, and an empty state offering generation.
struct SummaryTab: View {
    let meeting: Meeting
    let settings: AppSettings
    let isSummarizing: Bool
    let isTranslatingSummary: Bool
    /// The language an in-flight translation targets, to label the inline
    /// progress line. `nil` whenever `isTranslatingSummary` is false.
    var translationTargetLanguage: MeetingLanguage?
    /// (stage, total) when a long transcript is summarized in parts; nil for
    /// single-pass summaries.
    var summaryProgress: (stage: Int, total: Int)?
    /// Approximate words the model has streamed so far in the current
    /// request; nil until text starts arriving.
    var summaryWordsReceived: Int?
    /// The unformatted draft streaming in for the request in flight; empty
    /// before its first fragment.
    var summaryDraft = ""
    /// When the request in flight started, for the elapsed counter.
    var summaryRequestStartedAt: Date?
    /// Currently selected summary's id; falls back to the newest when nil or
    /// no longer present (e.g. it was just deleted).
    let selectedSummaryID: UUID?
    let hasAnyTranscript: Bool
    let onGenerate: () -> Void
    let onCancel: () -> Void
    let onSelectSummary: (Summary) -> Void
    let onDeleteSummary: (Summary) -> Void
    let onTranslateSummary: (Summary) -> Void
    let onCancelTranslateSummary: () -> Void
    let onCompare: () -> Void
    let onShare: () -> Void
    let onCopySummary: (Summary) -> Void
    /// Taps a section's photo reference chip; `nil` when the meeting has no
    /// photos, hiding the chip row entirely (see `SummaryView.onShowPhoto`).
    var onShowPhoto: ((TimeInterval) -> Void)?

    private var controller: ReadAloudController { .shared }

    private var sortedSummaries: [Summary] {
        meeting.summaries.sorted { $0.createdAt > $1.createdAt }
    }

    private var selectedSummary: Summary? {
        sortedSummaries.first { $0.id == selectedSummaryID } ?? sortedSummaries.first
    }

    private var readAloudItem: ReadAloudItem? {
        selectedSummary.map { .summary($0, meeting: meeting) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isSummarizing || selectedSummary != nil {
                MeetingDetailSummaryBar(
                    meeting: meeting,
                    summaries: sortedSummaries,
                    selectedID: selectedSummary?.id,
                    isSummarizing: isSummarizing,
                    generatingTitle: generatingTitle,
                    onSelectSummary: onSelectSummary,
                    onGenerate: onGenerate,
                    onCompare: onCompare,
                    onTranslateSummary: onTranslateSummary,
                    onCopySummary: onCopySummary,
                    onShare: onShare,
                    onDeleteSummary: onDeleteSummary,
                    onCancel: onCancel,
                    onListen: listen
                )
            }

            if isSummarizing {
                generatingState
            } else if let selectedSummary {
                SummaryView(summary: selectedSummary, onShowPhoto: onShowPhoto)
            } else {
                summaryEmptyState(canGenerate: hasAnyTranscript)
            }

            if isTranslatingSummary, let translationTargetLanguage {
                translatingRow(to: translationTargetLanguage)
            }
        }
    }

    private var generatingTitle: String {
        settings.summaryTemplates.first { $0.id == settings.lastSummaryTemplateID }?.displayName
            ?? NSLocalizedString("detail.summary.untitled", comment: "Summary")
    }

    private func listen() {
        guard let item = readAloudItem else { return }
        controller.toggle(item, settings: settings)
    }

    /// Streaming replaces the finished summary in place — the pill reads
    /// "<template> · writing…" above and this streams the raw draft with one
    /// discreet status line underneath; no card, no border.
    private var generatingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            SummaryDraftView(draft: summaryDraft, startedAt: summaryRequestStartedAt)
            if let progressValue {
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                    .tint(Theme.ink)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                    Text(generatingStats(at: context.date))
                }
                .font(Theme.footnote)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 8)
    }

    /// "<model> · 12s · 348 words"
    private func generatingStats(at now: Date) -> String {
        let model = settings.summaryModel(for: settings.aiProvider)
        let elapsed = Int(now.timeIntervalSince(summaryRequestStartedAt ?? now))
        let words = summaryWordsReceived ?? 0
        if model.isEmpty {
            return String(
                format: NSLocalizedString("detail.summary.generating.stats.no_model", comment: "elapsed and words"),
                elapsed, words
            )
        }
        return String(
            format: NSLocalizedString("detail.summary.generating.stats", comment: "model, elapsed, words"),
            model, elapsed, words
        )
    }

    private var progressValue: Double? {
        guard let progress = summaryProgress, progress.total > 0 else { return nil }
        return Double(progress.stage) / Double(progress.total)
    }

    /// Same spot and weight as the generating state — a translation is quick
    /// and starts from an already-visible summary, so it gets one line with a
    /// cancel glyph, nothing more.
    private func translatingRow(to language: MeetingLanguage) -> some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .accessibilityHidden(true)
            Text(String(
                format: NSLocalizedString("detail.summary.translating_to", comment: "Translating to a language"),
                language.displayName
            ))
            .font(Theme.footnote)
            .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Button {
                onCancelTranslateSummary()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NSLocalizedString("detail.summary.cancel_translate", comment: "Cancel translation"))
        }
    }

    private func summaryEmptyState(canGenerate: Bool) -> some View {
        MeetingGenerateEmptyState(
            systemImage: "sparkles",
            title: NSLocalizedString("detail.summary.empty.title", comment: "No summary yet"),
            description: NSLocalizedString(
                canGenerate ? "detail.summary.empty.hint" : "detail.summary.needs_transcript",
                comment: "Summary empty state"
            ),
            actionTitle: canGenerate
                ? NSLocalizedString("detail.summary.generate", comment: "Generate summary")
                : nil,
            footnote: canGenerate ? summaryModelNudge : nil,
            action: onGenerate
        )
    }

    private var summaryModelNudge: String {
        MeetingGenerateEmptyState.modelNudge(
            provider: settings.aiProvider,
            model: settings.summaryModel(for: settings.aiProvider)
        )
    }
}

private struct SummaryDraftView: View {
    let draft: String
    let startedAt: Date?

    private static let endID = "summary.draft.end"

    var body: some View {
        if draft.isEmpty {
            ThinkingRow(startedAt: startedAt ?? Date())
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("detail.summary.draft.title", comment: "Live unformatted summary draft"))
                    .font(Theme.caption2Emphasized)
                    .foregroundStyle(Theme.textTertiary)
                ScrollViewReader { proxy in
                    ScrollView {
                        HStack(alignment: .lastTextBaseline, spacing: 4) {
                            Text(draft)
                                .font(Theme.footnote)
                                .italic()
                                .foregroundStyle(Theme.textSecondary)
                            StreamingCursor()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.endID)
                    }
                    .frame(maxHeight: 200)
                    .onChange(of: draft) {
                        proxy.scrollTo(Self.endID, anchor: .bottom)
                    }
                }
                .padding(12)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

/// The shared "nothing generated yet" layout for the detail tabs (Summary
/// and Wiki) — one glyph/title/description/button/footnote shape so the two
/// empty states cannot drift. `actionTitle`/`footnote`/`action` are all
/// gated on `actionTitle`: without it the state is description-only.
struct MeetingGenerateEmptyState: View {
    let systemImage: String
    let title: String
    let description: String
    var descriptionIdentifier: String?
    var actionTitle: String?
    var actionIdentifier: String?
    var footnote: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
                .accessibilityIdentifier(descriptionIdentifier ?? "")
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .inkProminent()
                    .accessibilityIdentifier(actionIdentifier ?? "")
                if let footnote {
                    Text(footnote)
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.top, 24)
    }

    /// The shared footnote under the generate button: "Will use <provider> ·
    /// model <model>" for a cloud pick, or the on-device wording when the
    /// resolved provider is Apple Intelligence.
    static func modelNudge(provider: AIProvider, model: String) -> String {
        if provider.kind == .appleOnDevice {
            return NSLocalizedString("detail.generate.on_device", comment: "On-device generation footnote")
        }
        guard !model.isEmpty else {
            return NSLocalizedString("detail.summary.model_missing", comment: "No summary model selected")
        }
        return String(
            format: NSLocalizedString("detail.summary.model_nudge", comment: "Summary model nudge"),
            provider.displayName,
            model
        )
    }
}
