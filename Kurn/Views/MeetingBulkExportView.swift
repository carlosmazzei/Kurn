//
//  MeetingBulkExportView.swift
//  Kurn
//
//  Exports several meetings at once from the list's selection mode: their
//  latest summaries and/or transcripts, one file per meeting or a single file
//  grouped by meeting, in any `MeetingExportFormat`. It only renders
//  `MeetingBulkExportViewModel`; the plan is `MeetingBulkExport`.
//

import KurnCore
import SwiftUI

struct MeetingBulkExportView: View {
    let onShare: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: MeetingBulkExportViewModel

    init(meetings: [Meeting], onShare: @escaping ([URL]) -> Void) {
        self.onShare = onShare
        _model = State(initialValue: MeetingBulkExportViewModel(meetings: meetings))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(
                        NSLocalizedString("share.select.summaries", comment: "Summaries"),
                        isOn: $model.export.includesSummaries
                    )
                    .accessibilityIdentifier("bulk_export.summaries")
                    Toggle(
                        NSLocalizedString("share.select.transcripts", comment: "Transcripts"),
                        isOn: $model.export.includesTranscripts
                    )
                    .accessibilityIdentifier("bulk_export.transcripts")
                } header: {
                    Text(NSLocalizedString("bulk_export.include", comment: "Include"))
                } footer: {
                    Text(model.export.availabilityText)
                }

                Section {
                    Picker(
                        NSLocalizedString("bulk_export.grouping", comment: "Files"),
                        selection: $model.export.grouping
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
                    Text(model.export.grouping.detail)
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
                    Button { model.copyAll() } label: {
                        Image(systemName: model.didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(!model.export.canExport)
                    .accessibilityLabel(NSLocalizedString("share.copy_all", comment: "Copy All"))
                    .accessibilityIdentifier("bulk_export.copy_all")
                }
            }
            .safeAreaBar(edge: .bottom) { shareBar }
            .errorAlert($model.error)
        }
        // Large only: at the medium height the share bar laid over the form
        // covers the grouping picker, so the choice it explains sits under
        // the button it changes.
        .presentationDetents([.large])
    }

    /// The same format picker and share button as `MeetingShareSelectionView`.
    private var shareBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(NSLocalizedString("share.format.picker", comment: "Format"))
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker(NSLocalizedString("share.format.picker", comment: "Format"), selection: $model.export.format) {
                    ForEach(MeetingExportFormat.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("bulk_export.format_picker")
            }

            Text(model.export.format.explanation)
                .font(Theme.caption)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task {
                    guard let urls = await model.share() else { return }
                    dismiss()
                    onShare(urls)
                }
            } label: {
                ZStack {
                    Text(model.export.shareButtonTitle).opacity(model.isExporting ? 0 : 1)
                    if model.isExporting {
                        ProgressView()
                            .accessibilityLabel(NSLocalizedString("share.exporting", comment: "Preparing files"))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .disabled(!model.canShare)
            .accessibilityIdentifier("bulk_export.share_button")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
