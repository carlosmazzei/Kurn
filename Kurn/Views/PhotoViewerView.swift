//
//  PhotoViewerView.swift
//  Kurn
//
//  Full-screen presentation of one `MeetingPhoto`, reached by tapping its
//  inline marker in `TranscriptView`. Shows the recognized (OCR) text below
//  the image when present, since that's the part a user is most likely to
//  want to read or copy.
//

import SwiftUI
import UIKit

struct PhotoViewerView: View {
    let photo: MeetingPhoto
    var onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteConfirm = false

    /// "Recording N · m:ss into the meeting". N is the recording's position in
    /// its meeting, matching the numbering the Audio tab shows; a photo whose
    /// recording was deleted just shows the timestamp.
    private var caption: String {
        let offset = photo.capturedAt.clockDisplay
        let recordings = photo.recording?.meeting?.recordings
            .sorted(by: { $0.recordedAt < $1.recordedAt }) ?? []
        let index = recordings.firstIndex(where: { $0.id == photo.recording?.id })
        guard let index else { return offset }
        return String(
            format: NSLocalizedString("photo.caption", comment: "Recording position caption"),
            index + 1,
            offset
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let uiImage = UIImage(contentsOfFile: photo.fileURL.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityIgnoresInvertColors(true)
                            .accessibilityLabel(NSLocalizedString(
                                "photo.captured_image",
                                comment: "Accessibility label for a photo captured during recording"
                            ))
                    } else {
                        ContentUnavailableView(
                            NSLocalizedString("photo.unavailable", comment: "Photo unavailable"),
                            systemImage: "photo"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    if let text = photo.recognizedText, !text.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(NSLocalizedString("photo.recognized_text", comment: "Recognized text").uppercased())
                                .font(Theme.caption2Emphasized).tracking(0.8)
                                .foregroundStyle(Theme.textTertiary)
                            Text(text)
                                .font(Theme.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                }
                .padding()
            }
            .navigationTitle(NSLocalizedString("photo.title", comment: "Photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if onDelete != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Theme.destructive)
                        }
                        .accessibilityLabel(NSLocalizedString("photo.delete", comment: "Delete Photo"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.ink)
                }
            }
        }
        .kurnDialog(
            isPresented: $showingDeleteConfirm,
            iconSystemName: "trash.fill",
            iconTint: Theme.destructive,
            title: NSLocalizedString("photo.delete.confirm", comment: "Delete this photo?"),
            message: NSLocalizedString(
                "photo.delete.message",
                comment: "Its recognized text and any summary references to it are removed too."
            ),
            primaryTitle: NSLocalizedString("photo.delete", comment: "Delete Photo"),
            primaryRole: .destructive,
            primaryAction: {
                onDelete?()
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel"),
            secondaryAction: {}
        )
    }
}

/// A small square thumbnail for `MeetingDetailView`'s photo strip — the
/// gallery that's visible as soon as a recording is saved, independent of
/// `TranscriptView`'s inline markers (which need transcript segments to
/// anchor to and so stay empty until transcription finishes).
struct PhotoThumbnail: View {
    let photo: MeetingPhoto
    var size: CGFloat = 64
    var cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let uiImage = UIImage(contentsOfFile: photo.fileURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .accessibilityIgnoresInvertColors(true)
            } else {
                Rectangle()
                    .fill(Theme.textTertiary.opacity(0.15))
                    .overlay(Image(systemName: "photo").foregroundStyle(Theme.textTertiary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(NSLocalizedString("photo.captured_image", comment: "Photo captured during recording"))
        .accessibilityAddTraits(.isButton)
    }
}
