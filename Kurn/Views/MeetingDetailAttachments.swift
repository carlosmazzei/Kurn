//
//  MeetingDetailAttachments.swift
//  Kurn
//
//  The Audio tab's "Attachments" section: the PDFs attached to the meeting,
//  each opening in Quick Look, swipe to delete, and an "Add PDF" row that
//  opens the Files picker. Isolated here, like `MeetingDetailPhotos.swift`,
//  so the main view file stays under SwiftLint's file-length limit. It only
//  renders: state and actions are `MeetingAttachmentsViewModel`'s, the row's
//  text is `MeetingAttachment.detailsText`.
//

import KurnCore
import SwiftData
import SwiftUI

extension MeetingDetailView {
    var attachmentsSection: some View {
        Section {
            ForEach(meeting.sortedAttachments) { attachment in
                Button { attachments.preview(attachment) } label: {
                    AttachmentRow(attachment: attachment)
                }
                .buttonStyle(.plain)
                .accessibilityHint(NSLocalizedString("detail.attachments.open_hint", comment: "Opens the document"))
                .accessibilityIdentifier("detail.attachments.row")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { attachments.requestDelete(attachment) } label: {
                        Label(NSLocalizedString("common.delete", comment: "Delete"), systemImage: "trash")
                    }
                    .accessibilityIdentifier("detail.attachments.delete")
                }
            }
            addAttachmentRow
        } header: {
            Text(NSLocalizedString("detail.attachments", comment: "Documents attached to the meeting"))
        } footer: {
            if attachments.isImporting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(String(
                        format: NSLocalizedString("detail.attachments.reading", comment: "Reading an attachment"),
                        attachments.importingName ?? ""
                    ))
                }
            }
        }
    }

    private var addAttachmentRow: some View {
        Button { attachments.requestImport() } label: {
            HStack(spacing: 8) {
                if attachments.isImporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.link)
                        .accessibilityHidden(true)
                }
                Text(attachments.isImporting
                    ? NSLocalizedString("detail.attachments.adding", comment: "Adding PDF")
                    : NSLocalizedString("detail.attachments.add", comment: "Add PDF"))
                    .font(Theme.body)
                    .foregroundStyle(Theme.link)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(attachments.isImporting)
        .accessibilityIdentifier("detail.attachments.add")
    }
}

extension View {
    /// Confirmation dialog before deleting a swiped PDF attachment (G1),
    /// attached at the root of `MeetingDetailView` so the overlay is always
    /// centered on screen even when the Documents section is scrolled partially
    /// out of view.
    func attachmentDeleteDialog(
        attachments: MeetingAttachmentsViewModel,
        modelContext: ModelContext
    ) -> some View {
        kurnDialog(
            isPresented: Binding(
                get: { attachments.pendingDelete != nil },
                set: { if !$0 { attachments.cancelDelete() } }
            ),
            iconSystemName: "trash.circle.fill",
            iconTint: Theme.warning,
            title: NSLocalizedString("detail.attachments.delete_confirm.title", comment: "Delete attachment confirmation"),
            message: String(
                format: NSLocalizedString("detail.attachments.delete_confirm.message", comment: "Delete attachment message"),
                attachments.pendingDelete?.displayName ?? ""
            ),
            primaryTitle: NSLocalizedString("common.delete", comment: "Delete"),
            primaryRole: .destructive,
            primaryAction: { attachments.confirmDelete(context: modelContext) },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }
}

/// One attached document: a grey doc well, its name, page count and size, a
/// chevron, and a note when no text could be read from it (it then adds
/// nothing to the summary).
private struct AttachmentRow: View {
    let attachment: MeetingAttachment

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.fill)
                    .frame(width: 30, height: 30)
                Image(systemName: "doc.text")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(Theme.subheadlineEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(attachment.detailsText)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                if !attachment.hasExtractedText {
                    Label(
                        NSLocalizedString("detail.attachments.no_text", comment: "No readable text in the document"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(Theme.caption)
                    .foregroundStyle(Theme.warning)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}
