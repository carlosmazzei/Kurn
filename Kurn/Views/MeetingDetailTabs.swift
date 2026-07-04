//
//  MeetingDetailTabs.swift
//  Kurn
//
//  Tab content split out of `MeetingDetailView` to keep that file under
//  SwiftLint's length limits: the speaker-attributed transcript tab (with inline
//  speaker renaming) and the AI summary tab.
//

import SwiftUI

/// Transcript tab content: speaker filter chips + speaker-attributed bubbles +
/// inline speaker renaming.
struct TranscriptTab: View {
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
                    offset: meeting.startOffset(of: recording),
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
        .kurnCard(padding: 12, cornerRadius: 12)
    }
}

/// Summary tab content: the generated summary (or an empty state) plus the
/// generate/regenerate button.
struct SummaryTab: View {
    let meeting: Meeting
    let settings: AppSettings
    let isSummarizing: Bool
    let isCancellingSummary: Bool
    /// (stage, total) when a long transcript is summarized in parts; nil for
    /// single-pass summaries.
    var summaryProgress: (stage: Int, total: Int)?
    let onGenerate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if let summary = meeting.summary {
            VStack(alignment: .leading, spacing: 16) {
                if isSummarizing {
                    summaryProgressPanel
                }
                SummaryView(summary: summary)
                if !isSummarizing {
                    generateButton(regenerate: true)
                }
            }
        } else if isSummarizing {
            summaryProgressPanel
                .padding(.top, 24)
        } else if meeting.hasAnyTranscript {
            summaryEmptyState(canGenerate: true)
        } else {
            summaryEmptyState(canGenerate: false)
        }
    }

    private var summaryProgressPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.14))
                        .frame(width: 42, height: 42)
                    if isCancellingSummary {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(progressTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(progressSubtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(Theme.accent)

            Button(role: .cancel) {
                onCancel()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                    Text(NSLocalizedString("detail.summary.cancel", comment: "Cancel summary"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
            }
            .buttonStyle(.bordered)
            .disabled(isCancellingSummary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
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
                Text(summaryModelNudge)
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.fill, in: Capsule())

            if canGenerate { generateButton(regenerate: false) }
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private var summarizingLabel: String {
        if let progress = summaryProgress {
            return String(
                format: NSLocalizedString("detail.summarizing.progress", comment: "Summarizing part i of n"),
                progress.stage, progress.total
            )
        }
        return NSLocalizedString("detail.summarizing", comment: "Generating...")
    }

    private var progressTitle: String {
        isCancellingSummary
            ? NSLocalizedString("detail.summary.cancelling", comment: "Cancelling summary")
            : summarizingLabel
    }

    private var progressSubtitle: String {
        if isCancellingSummary {
            return NSLocalizedString("detail.summary.cancelling.subtitle", comment: "Cancelling summary subtitle")
        }
        if summaryProgress != nil {
            return NSLocalizedString("detail.summary.progress.subtitle", comment: "Staged summary subtitle")
        }
        return NSLocalizedString("detail.summary.progress.single.subtitle", comment: "Single-pass summary subtitle")
    }

    private var progressValue: Double? {
        guard let progress = summaryProgress, progress.total > 0 else { return nil }
        return Double(progress.stage) / Double(progress.total)
    }

    private var summaryModelNudge: String {
        let provider = settings.aiProvider
        let model = settings.summaryModel(for: provider)
        guard !model.isEmpty else {
            return NSLocalizedString("detail.summary.model_missing", comment: "No summary model selected")
        }
        return String(
            format: NSLocalizedString("detail.summary.model_nudge", comment: "Summary model nudge"),
            provider.displayName,
            model
        )
    }

    private func generateButton(regenerate: Bool) -> some View {
        Button { onGenerate() } label: {
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
        .disabled(isSummarizing)
    }
}
