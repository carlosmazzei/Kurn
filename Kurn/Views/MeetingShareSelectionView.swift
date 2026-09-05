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
import KurnCore
import UIKit

struct MeetingShareSelectionView: View {
    let meeting: Meeting
    let onShare: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selection: MeetingShareSelection
    @State private var copiedRowID: UUID?
    @State private var copiedAll = false
    @State private var shareError: AppError?

    init(meeting: Meeting, preselectedSummary: Summary?, onShare: @escaping ([URL]) -> Void) {
        self.meeting = meeting
        self.onShare = onShare
        _selection = State(initialValue: MeetingShareSelection(meeting: meeting, preselectedSummary: preselectedSummary))
    }

    private var sortedSummaries: [Summary] { selection.sortedSummaries }

    private var transcribedRecordings: [(index: Int, recording: Recording)] { selection.transcribedRecordings }

    private var hasSelection: Bool { selection.hasSelection }

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
                        .accessibilityIdentifier("share.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        copyAll()
                    } label: {
                        Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(!hasSelection)
                    .accessibilityLabel(NSLocalizedString("share.copy_all", comment: "Copy All"))
                    .accessibilityIdentifier("share.copy_all")
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
                Picker(NSLocalizedString("share.format.picker", comment: "Format"), selection: $selection.format) {
                    ForEach(MeetingShareFormat.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("share.format_picker")
            }

            Text(selection.format.explanation)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("share.format_explanation")

            Button {
                performShare()
            } label: {
                Text(selection.shareButtonTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(!hasSelection)
            .accessibilityIdentifier("share.share_button")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func summaryRow(_ summary: Summary) -> some View {
        HStack(spacing: 12) {
            selectableLabel(
                title: MeetingShareSelection.summaryTitle(for: summary),
                subtitle: nil,
                isSelected: selection.isSelected(summary)
            ) {
                selection.toggle(summary)
            }
            copyButton(id: summary.id) {
                selection.markdown(for: summary)
            }
        }
    }

    private func transcriptRow(index: Int, recording: Recording) -> some View {
        HStack(spacing: 12) {
            selectableLabel(
                title: MeetingShareSelection.transcriptTitle(index: index),
                subtitle: recording.recordedAt.meetingDisplay,
                isSelected: selection.isSelected(recording)
            ) {
                selection.toggle(recording)
            }
            copyButton(id: recording.id) {
                selection.markdown(for: recording)
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

    private func flashCopied(_ id: UUID) {
        copiedRowID = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if copiedRowID == id { copiedRowID = nil }
        }
    }

    private func copyAll() {
        let combined = selection.combinedMarkdown()
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
            let urls = try selection.exportItems().map {
                try MeetingExport.temporaryFile(markdown: $0.markdown, suggestedName: $0.suggestedName)
            }
            dismiss()
            onShare(urls)
        } catch {
            shareError = .audioError(error.localizedDescription)
        }
    }
}
