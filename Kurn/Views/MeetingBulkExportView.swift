//
//  MeetingBulkExportView.swift
//  Kurn
//
//  Exports several meetings at once from the list's selection mode: their
//  latest summaries and/or transcripts, one file per meeting or a single file
//  grouped by meeting, in any `MeetingExportFormat`. The planning lives in
//  `MeetingBulkExport`; this view only renders it and writes the files.
//

import KurnCore
import SwiftUI

struct MeetingBulkExportView: View {
    let onShare: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var export: MeetingBulkExport
    @State private var copied = false
    @State private var shareError: AppError?
    @State private var isExporting = false

    init(meetings: [Meeting], onShare: @escaping ([URL]) -> Void) {
        self.onShare = onShare
        _export = State(initialValue: MeetingBulkExport(meetings: meetings))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        NSLocalizedString("share.select.summaries", comment: "Summaries"),
                        isOn: $export.includesSummaries
                    )
                    .accessibilityIdentifier("bulk_export.summaries")
                    Toggle(
                        NSLocalizedString("share.select.transcripts", comment: "Transcripts"),
                        isOn: $export.includesTranscripts
                    )
                    .accessibilityIdentifier("bulk_export.transcripts")
                } header: {
                    Text(NSLocalizedString("bulk_export.include", comment: "Include"))
                } footer: {
                    Text(export.availabilityText)
                }

                Section {
                    Picker(
                        NSLocalizedString("bulk_export.grouping", comment: "Files"),
                        selection: $export.grouping
                    ) {
                        ForEach(MeetingBulkExport.Grouping.allCases) { grouping in
                            Text(grouping.title).tag(grouping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("bulk_export.grouping")
                } header: {
                    Text(NSLocalizedString("bulk_export.grouping", comment: "Files"))
                } footer: {
                    Text(export.grouping == .singleFile
                        ? NSLocalizedString("bulk_export.grouping.single.detail", comment: "Single file detail")
                        : NSLocalizedString("bulk_export.grouping.per_meeting.detail", comment: "Per-meeting detail"))
                }
            }
            .navigationTitle(NSLocalizedString("bulk_export.title", comment: "Export meetings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                        .accessibilityIdentifier("bulk_export.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: copyAll) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(!export.canExport)
                    .accessibilityLabel(NSLocalizedString("share.copy_all", comment: "Copy All"))
                    .accessibilityIdentifier("bulk_export.copy_all")
                }
            }
            .safeAreaBar(edge: .bottom) { shareBar }
            .errorAlert($shareError)
        }
        .presentationDetents([.medium, .large])
    }

    /// The same format picker and share button as `MeetingShareSelectionView`.
    private var shareBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(NSLocalizedString("share.format.picker", comment: "Format"))
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker(NSLocalizedString("share.format.picker", comment: "Format"), selection: $export.format) {
                    ForEach(MeetingExportFormat.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("bulk_export.format_picker")
            }

            Text(export.format.explanation)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: performShare) {
                ZStack {
                    Text(export.shareButtonTitle).opacity(isExporting ? 0 : 1)
                    if isExporting {
                        ProgressView()
                            .accessibilityLabel(NSLocalizedString("share.exporting", comment: "Preparing files"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(!export.canExport || isExporting)
            .accessibilityIdentifier("bulk_export.share_button")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func copyAll() {
        let text = export.clipboardText()
        guard !text.isEmpty else { return }
        MeetingPasteboard.copy(text)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Builds the documents on the main actor, where the meetings live, then
    /// renders and writes the files in the background.
    private func performShare() {
        let items = export.exportItems()
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
