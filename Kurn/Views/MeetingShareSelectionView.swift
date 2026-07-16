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
    let meeting: Meeting
    let onShare: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedSummaryIDs: Set<UUID>
    @State private var selectedRecordingIDs: Set<UUID>
    @State private var copiedRowID: UUID?
    @State private var copiedAll = false
    @State private var shareError: AppError?

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
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("share.share_action", comment: "Share")) {
                        performShare()
                    }
                    .disabled(!hasSelection)
                }
            }
            .errorAlert($shareError)
        }
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
                MeetingExport.summaryMarkdown(for: meeting, summary: summary)
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
                MeetingExport.transcriptMarkdown(for: meeting, recording: recording)
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
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
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
        let summaryTexts = sortedSummaries
            .filter { selectedSummaryIDs.contains($0.id) }
            .map { MeetingExport.summaryMarkdown(for: meeting, summary: $0) }
        let transcriptTexts = transcribedRecordings
            .filter { selectedRecordingIDs.contains($0.recording.id) }
            .map { MeetingExport.transcriptMarkdown(for: meeting, recording: $0.recording) }
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
            var urls: [URL] = []
            for summary in sortedSummaries where selectedSummaryIDs.contains(summary.id) {
                let text = MeetingExport.summaryMarkdown(for: meeting, summary: summary)
                let name = "\(meeting.title)-summary-\(summary.templateName ?? "\(urls.count + 1)")"
                urls.append(try MeetingExport.temporaryFile(markdown: text, suggestedName: name))
            }
            for entry in transcribedRecordings where selectedRecordingIDs.contains(entry.recording.id) {
                let text = MeetingExport.transcriptMarkdown(for: meeting, recording: entry.recording)
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
