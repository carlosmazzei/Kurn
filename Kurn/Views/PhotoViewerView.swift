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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let uiImage = UIImage(contentsOfFile: photo.fileURL.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    if let text = photo.recognizedText, !text.isEmpty {
                        Text(NSLocalizedString("photo.recognized_text", comment: "Recognized text").uppercased())
                            .font(Theme.caption2Emphasized).tracking(0.8)
                            .foregroundStyle(Theme.textTertiary)
                        Text(text)
                            .font(Theme.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }
            .navigationTitle((photo.capturedAt).clockDisplay)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if onDelete != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingDeleteConfirm = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(NSLocalizedString("photo.delete", comment: "Delete Photo"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
        .kurnDialog(
            isPresented: $showingDeleteConfirm,
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
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

    var body: some View {
        Group {
            if let uiImage = UIImage(contentsOfFile: photo.fileURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Theme.textTertiary.opacity(0.15))
                    .overlay(Image(systemName: "photo").foregroundStyle(Theme.textTertiary))
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(NSLocalizedString("photo.captured_image", comment: "Photo captured during recording"))
        .accessibilityAddTraits(.isButton)
    }
}
