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
                Divider()
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                sectionLabel(NSLocalizedString("detail.photos", comment: "Photos"))
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(allPhotos) { photo in
                            Button {
                                presentedPhoto = photo
                            } label: {
                                VStack(spacing: 4) {
                                    PhotoThumbnail(photo: photo)
                                    Text(meetingRelativeTime(of: photo).clockDisplay)
                                        .font(Theme.caption2)
                                        .foregroundStyle(Theme.textTertiary)
                                        .monospacedDigit()
                                }
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

    /// A photo's timestamp on the meeting's own timeline — its
    /// recording-relative `capturedAt` plus that recording's `startOffset`
    /// — so the strip reads the same "time since the meeting began" as every
    /// other timestamp in the UI (transcript citations, the Summary photo
    /// reference chips), not the time within whichever segment it happened
    /// to be taken in.
    private func meetingRelativeTime(of photo: MeetingPhoto) -> TimeInterval {
        guard let recording = sortedRecordings.first(where: { $0.photos.contains(where: { $0.id == photo.id }) }) else {
            return photo.capturedAt
        }
        return photo.capturedAt + meeting.startOffset(of: recording)
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
