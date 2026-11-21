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
    @ScaledMetric(relativeTo: .caption2) private var avatarSize: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

        VStack(alignment: .leading, spacing: 6) {
            Button {
                onSeek(segment.startTime)
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(color.opacity(0.2)).frame(width: avatarSize, height: avatarSize)
                        Text(String(name.prefix(1)).uppercased())
                            .font(Theme.caption2Emphasized)
                            .foregroundStyle(color)
                    }
                    .accessibilityHidden(true)
                    Text(name)
                        .font(Theme.footnoteEmphasized)
                        .foregroundStyle(color)
                    Text((segment.startTime + offset).clockDisplay)
                        .font(Theme.caption2)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

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
                                .foregroundStyle(Theme.accent)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(NSLocalizedString("transcript.view_photo", comment: "View photo"))
                    }
                }
                .padding(.leading, 34)
            }

            Button {
                onSeek(segment.startTime)
            } label: {
                Text(segment.text)
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.leading, 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            isActive ? AnyShapeStyle(color.opacity(0.12)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? color.opacity(0.6) : .clear, lineWidth: 1.5)
        )
    }
}
