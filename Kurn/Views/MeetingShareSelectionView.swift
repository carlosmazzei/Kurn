//
//  MeetingShareSelectionView.swift
//  Kurn
//
//  Lets the user choose which of a meeting's transcripts and summaries to
//  share or copy, and in which format (Markdown, Obsidian, PDF, Word, HTML or
//  plain text). Each selected item is exported as its own file; sharing hands
//  the resulting URLs back to the caller to drive the iOS share sheet with
//  multiple attachments at once.
//

import SwiftUI
import KurnCore
import UIKit

struct MeetingShareSelectionView: View {
    let meeting: Meeting
    let onShare: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selection: MeetingShareSelection
    @State private var copiedAll = false
    @State private var shareError: AppError?
    @State private var isExporting = false

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
            Form {
                if !sortedSummaries.isEmpty {
                    Section(NSLocalizedString("share.select.summaries", comment: "Summaries")) {
                        ForEach(sortedSummaries) { summary in
                            selectableRow(
                                title: MeetingShareSelection.summaryTitle(for: summary),
                                subtitle: summary.createdAt.meetingDisplay,
                                isSelected: selection.isSelected(summary)
                            ) {
                                selection.toggle(summary)
                            }
                        }
                    }
                }
                if !transcribedRecordings.isEmpty {
                    Section(NSLocalizedString("share.select.transcripts", comment: "Transcripts")) {
                        ForEach(transcribedRecordings, id: \.recording.id) { entry in
                            selectableRow(
                                title: MeetingShareSelection.transcriptTitle(index: entry.index),
                                subtitle: entry.recording.recordedAt.meetingDisplay,
                                isSelected: selection.isSelected(entry.recording)
                            ) {
                                selection.toggle(entry.recording)
                            }
                        }
                    }
                }
                Section {
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(MeetingExportFormat.allCases, id: \.self) { option in
                            FilterChip(
                                title: option.title,
                                isSelected: selection.format == option
                            ) {
                                selection.format = option
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("share.format_picker")
                } header: {
                    Text(NSLocalizedString("share.format.picker", comment: "Format"))
                } footer: {
                    Text(selection.format.explanation)
                        .accessibilityIdentifier("share.format_explanation")
                }
            }
            .navigationTitle(NSLocalizedString("share.select.title", comment: "Share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                        .accessibilityIdentifier("share.cancel")
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .errorAlert($shareError)
        }
        // Sized here rather than at the `.sheet` call site, matching
        // `CrossMeetingSpeakerMatchView`: this view is only ever presented as
        // a sheet, so how tall that sheet should be is a property of its own
        // content. `.large` stays for the ones with a long list.
        .presentationDetents([.medium, .large])
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                copyAll()
            } label: {
                Image(systemName: copiedAll ? "checkmark" : "doc.on.doc")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .disabled(!hasSelection)
            .accessibilityLabel(NSLocalizedString("share.copy_all", comment: "Copy All"))
            .accessibilityIdentifier("share.copy_all")

            Button {
                performShare()
            } label: {
                // A long meeting's PDF takes a moment to typeset; the spinner
                // keeps the button from reading as unresponsive meanwhile.
                ZStack {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .accessibilityHidden(true)
                        Text(selection.shareButtonTitle)
                    }
                    .opacity(isExporting ? 0 : 1)
                    if isExporting {
                        ProgressView()
                            .accessibilityLabel(NSLocalizedString("share.exporting", comment: "Preparing files"))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(Theme.onInk)
            }
            .inkProminent()
            .disabled(!hasSelection || isExporting)
            .accessibilityIdentifier("share.share_button")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func selectableRow(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Theme.link : Theme.textTertiary)
                    .accessibilityHidden(true)
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
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copyAll() {
        let combined = selection.combinedClipboardText()
        guard !combined.isEmpty else { return }
        MeetingPasteboard.copy(combined)
        copiedAll = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedAll = false
        }
    }

    /// Builds the documents here, on the main actor where the meeting lives,
    /// then renders and writes the files in the background.
    private func performShare() {
        let items = selection.exportItems()
        guard !items.isEmpty, !isExporting else { return }
        let pageSize = ExportPageSize.preferred(forRegion: Locale.current.region?.identifier)
        isExporting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try items.map { try $0.writeTemporaryFile(pageSize: pageSize) } }
            }.value
            isExporting = false
            switch result {
            case .success(let urls):
                dismiss()
                onShare(urls)
            case .failure(let error):
                shareError = .audioError(error.localizedDescription)
            }
        }
    }
}
