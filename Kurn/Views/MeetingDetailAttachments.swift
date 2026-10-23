//
//  MeetingDetailAttachments.swift
//  Kurn
//
//  The Recordings tab's "Documents" section: the PDFs attached to the
//  meeting, each opening in Quick Look, swipe to delete, and an "Add PDF"
//  row that opens the Files picker. Isolated here, like
//  `MeetingDetailPhotos.swift`, so the main view file stays under
//  SwiftLint's file-length limit. The import itself is
//  `MeetingAttachmentImporter`; the same importer serves a PDF shared into
//  the app from elsewhere (`AttachToMeetingView`).
//

import KurnCore
import SwiftUI

extension MeetingDetailView {
    @ViewBuilder
    var attachmentsSection: some View {
        // One row, like `photosStrip`'s: a Divider alone in a List row is an
        // accessibility element with nothing to describe.
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.top, 12)
                .accessibilityHidden(true)
            sectionLabel(NSLocalizedString("detail.attachments", comment: "Documents attached to the meeting"))
                .padding(.top, 4)
        }
        .clearListRow(insets: EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
        ForEach(meeting.sortedAttachments) { attachment in
            Button { previewedAttachmentURL = attachment.fileURL } label: {
                AttachmentRow(attachment: attachment)
            }
            .buttonStyle(.plain)
            .accessibilityHint(NSLocalizedString("detail.attachments.open_hint", comment: "Opens the document"))
            .clearListRow(insets: EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { deleteAttachment(attachment) } label: {
                    Label(NSLocalizedString("common.delete", comment: "Delete"), systemImage: "trash")
                }
            }
        }
        addAttachmentButton
            .clearListRow(insets: EdgeInsets(top: 8, leading: 20, bottom: 24, trailing: 20))
    }

    private var addAttachmentButton: some View {
        Button { showingAttachmentImporter = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.info.opacity(0.12)).frame(width: 34, height: 34)
                    if isImportingAttachments {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(.footnote, design: .default, weight: .bold)).foregroundStyle(Theme.info)
                            .accessibilityHidden(true)
                    }
                }
                Text(isImportingAttachments
                    ? NSLocalizedString("detail.attachments.adding", comment: "Adding PDF")
                    : NSLocalizedString("detail.attachments.add", comment: "Add PDF"))
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.textSecondary)
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
        .disabled(isImportingAttachments)
        .accessibilityIdentifier("detail.attachments.add")
    }

    /// The Files picker's result: imports the chosen PDFs into the meeting.
    func importAttachments(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            actionError = .attachmentImportFailed(error.localizedDescription)
        case .success(let urls):
            guard !urls.isEmpty else { return }
            isImportingAttachments = true
            Task {
                let report = await MeetingAttachmentImporter(context: modelContext)
                    .importPDFs(from: urls, into: meeting)
                isImportingAttachments = false
                if let failure = report.firstFailure { actionError = failure }
            }
        }
    }

    func deleteAttachment(_ attachment: MeetingAttachment) {
        if previewedAttachmentURL == attachment.fileURL { previewedAttachmentURL = nil }
        do throws(AppError) {
            try MeetingLibrary(context: modelContext).deleteAttachment(attachment)
        } catch {
            actionError = error
        }
    }
}

/// One attached document: its name, page count and size, and a note when no
/// text could be read from it (it then adds nothing to the summary).
private struct AttachmentRow: View {
    let attachment: MeetingAttachment

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(Theme.title3)
                .foregroundStyle(Theme.info)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.displayName)
                    .font(Theme.subheadlineEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(details)
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
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    private var details: String {
        let pages = attachment.pageCount == 1
            ? NSLocalizedString("detail.attachments.one_page", comment: "1 page")
            : String(format: NSLocalizedString("detail.attachments.pages", comment: "N pages"), attachment.pageCount)
        let size = ByteCountFormatter.string(fromByteCount: attachment.fileSize, countStyle: .file)
        return "\(pages) · \(size)"
    }
}
