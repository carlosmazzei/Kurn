//
//  TranscriptView.swift
//  Kurn
//
//  Renders speaker-attributed transcript segments. Tapping a segment asks the
//  parent to seek the audio player to that timestamp. The active segment (while
//  the owning recording plays) is highlighted.
//

import KurnCore
import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let speakers: [Speaker]
    /// Current playback time within the owning recording (or nil if not playing).
    let activeTime: TimeInterval?
    /// Seconds from the meeting start to this recording, added only to the
    /// displayed timestamp so a multi-segment transcript reads as one continuous
    /// timeline. Seeking and active-segment highlighting still use the raw,
    /// recording-relative times, since playback is per recording.
    var offset: TimeInterval = 0
    /// Recording-relative highlight markers, same convention as `startTime`.
    var highlights: [Highlight] = []
    /// Photos captured during this recording, same recording-relative
    /// timestamp convention as `highlights`.
    var photos: [MeetingPhoto] = []
    let onSeek: (TimeInterval) -> Void
    /// Presents a photo full-screen. `nil` (the default) hides the inline
    /// photo marker entirely, so call sites that don't pass `photos` don't
    /// need to pass this either.
    var onShowPhoto: ((MeetingPhoto) -> Void)?
    @ScaledMetric(relativeTo: .caption2) private var avatarSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(segments) { segment in
                segmentRow(segment)
            }
        }
    }

    @ViewBuilder
    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        let speaker = speakers.first { $0.label == segment.speakerLabel }
        let name = speaker?.displayName ?? segment.speakerLabel
        let color = Color(hex: speaker?.color ?? "#888888")
        let isActive = activeTime.map { $0 >= segment.startTime && $0 < segment.endTime } ?? false
        let matchingHighlights = highlights.filter { $0.timestamp >= segment.startTime && $0.timestamp < segment.endTime }
        let matchingPhotos = photos.filter { $0.capturedAt >= segment.startTime && $0.capturedAt < segment.endTime }

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(color.opacity(0.18)).frame(width: avatarSize, height: avatarSize)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color)
                }
                .accessibilityHidden(true)
                .accessibilityIgnoresInvertColors(true)
                Text(name)
                    .font(Theme.subheadlineEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                Button {
                    onSeek(segment.startTime)
                } label: {
                    Text((segment.startTime + offset).clockDisplay)
                        .font(Theme.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(
                    format: NSLocalizedString("transcript.seek_to", comment: "Seek to a timestamp"),
                    (segment.startTime + offset).clockDisplay
                ))
            }
            .frame(minHeight: 28)

            if !matchingHighlights.isEmpty || !matchingPhotos.isEmpty {
                FlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(matchingHighlights) { highlight in
                        Button {
                            onSeek(highlight.timestamp)
                        } label: {
                            Image(systemName: "bookmark.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.warning)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("transcript.jump_to_highlight", comment: "Jump to highlight"))
                    }
                    ForEach(matchingPhotos) { photo in
                        Button {
                            onShowPhoto?(photo)
                        } label: {
                            Image(systemName: "camera.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.link)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("transcript.view_photo", comment: "View photo"))
                    }
                }
                .padding(.leading, 30)
            }

            Button {
                onSeek(segment.startTime)
            } label: {
                Text(segment.text)
                    .font(Theme.body)
                    .lineSpacing(4)
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, isActive ? 10 : 0)
        .padding(.vertical, isActive ? 8 : 0)
        .background(
            isActive ? AnyShapeStyle(Theme.fill) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}
