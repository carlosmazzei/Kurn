//
//  MeetingShareSelectionView.swift
//  Kurn
//
//  Lets the user choose which of a meeting's transcripts and summaries to
//  share or copy. Each selected item is exported as its own Markdown file;
//  sharing hands the resulting URLs back to the caller to drive the iOS
//  share sheet with multiple attachments at once.
//

import SwiftUI
import UIKit

struct MeetingShareSelectionView: View {
    /// Output format for every export in this sheet: standard plain Markdown,
    /// or "Obsidian" (YAML frontmatter + `[[wikilinks]]` for speakers) — see
    /// `MeetingExport.markdown(for:summary:obsidianStyle:)`.
    private enum ShareFormat: String, CaseIterable {
        case standard, obsidian

        var title: String {
            switch self {
            case .standard: NSLocalizedString("share.format.standard", comment: "Standard")
            case .obsidian: NSLocalizedString("share.format.obsidian", comment: "Obsidian")
            }
        }

        /// What the choice actually changes in the exported file. Without it
        /// "Obsidian" is just a word next to "Standard" — nothing else on this
        /// screen reacts to the picker, so this line is the only feedback that
        /// the control did anything.
        var explanation: String {
            switch self {
            case .standard: NSLocalizedString("share.format.standard.detail", comment: "Standard format detail")
            case .obsidian: NSLocalizedString("share.format.obsidian.detail", comment: "Obsidian format detail")
            }
        }
    }

    let meeting: Meeting
    let onShare: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedSummaryIDs: Set<UUID>
    @State private var selectedRecordingIDs: Set<UUID>
    @State private var copiedRowID: UUID?
    @State private var copiedAll = false
    @State private var shareError: AppError?
    @State private var format: ShareFormat = .standard

    /// Defaults to every transcribed recording plus the summary currently
    /// shown on screen, matching the export this replaces.
    init(meeting: Meeting, preselectedSummary: Summary?, onShare: @escaping ([URL]) -> Void) {
        self.meeting = meeting
        self.onShare = onShare
        _selectedSummaryIDs = State(initialValue: preselectedSummary.map { [$0.id] } ?? [])
        let transcribedIDs = meeting.recordings.filter { $0.transcript != nil }.map(\.id)
        _selectedRecordingIDs = State(initialValue: Set(transcribedIDs))
    }

    private var sortedSummaries: [Summary] {
        meeting.summaries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Recordings with a transcript, numbered by their position among all of
    /// the meeting's recordings so "Recording N" matches the Recordings tab.
    private var transcribedRecordings: [(index: Int, recording: Recording)] {
        meeting.recordings
            .sorted { $0.recordedAt < $1.recordedAt }
            .enumerated()
            .filter { $0.element.transcript != nil }
            .map { (index: $0.offset, recording: $0.element) }
    }

    private var hasSelection: Bool {
        !selectedSummaryIDs.isEmpty || !selectedRecordingIDs.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if !sortedSummaries.isEmpty {
                    Section(NSLocalizedString("share.select.summaries", comment: "Summaries")) {
                        ForEach(sortedSummaries) { summary in
                            summaryRow(summary)
                        }
                    }
                }
                if !transcribedRecordings.isEmpty {
                    Section(NSLocalizedString("share.select.transcripts", comment: "Transcripts")) {
                        ForEach(transcribedRecordings, id: \.recording.id) { entry in
                            transcriptRow(index: entry.index, recording: entry.recording)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("share.select.title", comment: "Share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        copyAll()
                    } label: {
                        Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(!hasSelection)
                    .accessibilityLabel(NSLocalizedString("share.copy_all", comment: "Copy All"))
                }
            }
            // The format is a modifier on the export, not a segmentation of
            // the list — as a picker above the content it read as a tab bar
            // switching between two views, which is not what it does. Sitting
            // next to the action it modifies, it is read at the moment it
            // matters. As a safe-area bar it gets the system's glass
            // background rather than a hand-drawn `.bar` strip, matching
            // `MeetingChatView`'s composer.
            .safeAreaBar(edge: .bottom) { shareBar }
            .errorAlert($shareError)
        }
        // Sized here rather than at the `.sheet` call site, matching
        // `CrossMeetingSpeakerMatchView`: this view is only ever presented as
        // a sheet, so how tall that sheet should be is a property of its own
        // content. A meeting's two or three exportable items did not warrant
        // a full-height sheet; `.large` stays for the ones with a long list.
        .presentationDetents([.medium, .large])
    }

    private var shareBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(NSLocalizedString("share.format.picker", comment: "Format"))
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker(NSLocalizedString("share.format.picker", comment: "Format"), selection: $format) {
                    ForEach(ShareFormat.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            Text(format.explanation)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                performShare()
            } label: {
                Text(shareButtonTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(!hasSelection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "Share" alone while nothing is selected, "Share (3)" otherwise. The
    /// count is parenthesised rather than written into the sentence so it
    /// needs no plural handling in any of the seven localizations.
    private var shareButtonTitle: String {
        let share = NSLocalizedString("share.share_action", comment: "Share")
        let count = selectedSummaryIDs.count + selectedRecordingIDs.count
        return count > 0 ? "\(share) (\(count))" : share
    }

    private func summaryRow(_ summary: Summary) -> some View {
        HStack(spacing: 12) {
            selectableLabel(
                title: summaryTitle(for: summary),
                subtitle: nil,
                isSelected: selectedSummaryIDs.contains(summary.id)
            ) {
                toggleSummary(summary)
            }
            copyButton(id: summary.id) {
                MeetingExport.summaryMarkdown(for: meeting, summary: summary, obsidianStyle: format == .obsidian)
            }
        }
    }

    private func transcriptRow(index: Int, recording: Recording) -> some View {
        HStack(spacing: 12) {
            selectableLabel(
                title: String(format: NSLocalizedString("detail.recording_n", comment: ""), index + 1),
                subtitle: recording.recordedAt.meetingDisplay,
                isSelected: selectedRecordingIDs.contains(recording.id)
            ) {
                toggleRecording(recording)
            }
            copyButton(id: recording.id) {
                MeetingExport.transcriptMarkdown(for: meeting, recording: recording, obsidianStyle: format == .obsidian)
            }
        }
    }

    private func selectableLabel(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.subheadlineEmphasized)
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copyButton(id: UUID, text: @escaping () -> String) -> some View {
        Button {
            UIPasteboard.general.string = text()
            flashCopied(id)
        } label: {
            Image(systemName: copiedRowID == id ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copiedRowID == id ? Theme.success : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString("share.copy", comment: "Copy"))
    }

    private func summaryTitle(for summary: Summary) -> String {
        let name = summary.templateName?.isEmpty == false
            ? summary.templateName!
            : NSLocalizedString("detail.summary.untitled", comment: "Summary")
        return "\(name) · \(summary.createdAt.shortTime)"
    }

    private func toggleSummary(_ summary: Summary) {
        if selectedSummaryIDs.contains(summary.id) {
            selectedSummaryIDs.remove(summary.id)
        } else {
            selectedSummaryIDs.insert(summary.id)
        }
    }

    private func toggleRecording(_ recording: Recording) {
        if selectedRecordingIDs.contains(recording.id) {
            selectedRecordingIDs.remove(recording.id)
        } else {
            selectedRecordingIDs.insert(recording.id)
        }
    }

    private func flashCopied(_ id: UUID) {
        copiedRowID = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copiedRowID == id { copiedRowID = nil }
        }
    }

    private func copyAll() {
        let obsidianStyle = format == .obsidian
        let summaryTexts = sortedSummaries
            .filter { selectedSummaryIDs.contains($0.id) }
            .map { MeetingExport.summaryMarkdown(for: meeting, summary: $0, obsidianStyle: obsidianStyle) }
        let transcriptTexts = transcribedRecordings
            .filter { selectedRecordingIDs.contains($0.recording.id) }
            .map { MeetingExport.transcriptMarkdown(for: meeting, recording: $0.recording, obsidianStyle: obsidianStyle) }
        let combined = (summaryTexts + transcriptTexts).joined(separator: "\n\n---\n\n")
        guard !combined.isEmpty else { return }
        UIPasteboard.general.string = combined
        copiedAll = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedAll = false
        }
    }

    private func performShare() {
        do {
            let obsidianStyle = format == .obsidian
            var urls: [URL] = []
            for summary in sortedSummaries where selectedSummaryIDs.contains(summary.id) {
                let text = MeetingExport.summaryMarkdown(for: meeting, summary: summary, obsidianStyle: obsidianStyle)
                let name = "\(meeting.title)-summary-\(summary.templateName ?? "\(urls.count + 1)")"
                urls.append(try MeetingExport.temporaryFile(markdown: text, suggestedName: name))
            }
            for entry in transcribedRecordings where selectedRecordingIDs.contains(entry.recording.id) {
                let text = MeetingExport.transcriptMarkdown(for: meeting, recording: entry.recording, obsidianStyle: obsidianStyle)
                let name = "\(meeting.title)-transcript-\(entry.index + 1)"
                urls.append(try MeetingExport.temporaryFile(markdown: text, suggestedName: name))
            }
            dismiss()
            onShare(urls)
        } catch {
            shareError = .audioError(error.localizedDescription)
        }
    }
}
