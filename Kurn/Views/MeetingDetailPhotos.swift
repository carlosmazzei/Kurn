//
//  MeetingDetailPhotos.swift
//  Kurn
//
//  The Recordings tab's photo strip. Isolated here (like
//  `MeetingDetailActions.swift`/`MeetingDetailToolbar.swift`) so the main
//  view file stays under SwiftLint's file-length limit.
//
//  Shown independently of `TranscriptView`'s inline photo markers, which
//  need transcript segments to anchor to and so stay empty until
//  transcription finishes — a photo taken during a recording that hasn't
//  been transcribed yet (the common case right after stopping) would
//  otherwise be invisible anywhere in the UI.
//

import SwiftUI

extension MeetingDetailView {
    /// All photos captured across every recording, oldest first — shown as
    /// soon as a recording is saved, not gated on transcription completing.
    var allPhotos: [MeetingPhoto] {
        sortedRecordings.flatMap(\.photos).sorted { $0.createdAt < $1.createdAt }
    }

    @ViewBuilder
    var photosStrip: some View {
        if !allPhotos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(NSLocalizedString("detail.photos", comment: "Photos"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(allPhotos) { photo in
                            Button {
                                presentedPhoto = photo
                            } label: {
                                PhotoThumbnail(photo: photo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .clearListRow(insets: EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
        }
    }

    /// Resolves a Summary photo-reference chip's meeting-relative timestamp
    /// (see `SummarySection.photoTimestamps`) to the nearest actual photo and
    /// presents it — the inverse of the meeting-relative-offset math
    /// `startOffset(of:)` already does for `jumpToTime`'s transcript
    /// citations. Nearest rather than exact: the model copies the photo
    /// line's own "[mm:ss]" stamp verbatim, but that stamp is itself only
    /// display precision (seconds, rounded), so an exact-equality match
    /// would be fragile for no benefit.
    func showPhoto(atMeetingRelativeTime time: TimeInterval) {
        var best: (photo: MeetingPhoto, distance: TimeInterval)?
        for recording in sortedRecordings {
            let offset = meeting.startOffset(of: recording)
            for photo in recording.photos {
                let distance = abs((photo.capturedAt + offset) - time)
                if best == nil || distance < best!.distance {
                    best = (photo, distance)
                }
            }
        }
        presentedPhoto = best?.photo
    }
}
