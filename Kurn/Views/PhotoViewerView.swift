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

    @Environment(\.dismiss) private var dismiss

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
    }
}
