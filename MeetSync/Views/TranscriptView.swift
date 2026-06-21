//
//  TranscriptView.swift
//  MeetSync
//
//  Renders speaker-attributed transcript segments. Tapping a segment asks the
//  parent to seek the audio player to that timestamp. The active segment (while
//  the owning recording plays) is highlighted.
//

import SwiftUI

struct TranscriptView: View {
    let segments: [TranscriptSegment]
    let speakers: [Speaker]
    /// Current playback time within the owning recording (or nil if not playing).
    let activeTime: TimeInterval?
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(segments) { segment in
                Button {
                    onSeek(segment.startTime)
                } label: {
                    segmentRow(segment)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func segmentRow(_ segment: TranscriptSegment) -> some View {
        let speaker = speakers.first { $0.label == segment.speakerLabel }
        let name = speaker?.displayName ?? segment.speakerLabel
        let color = Color(hex: speaker?.color ?? "#888888")
        let isActive = activeTime.map { $0 >= segment.startTime && $0 < segment.endTime } ?? false

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(color.opacity(0.2)).frame(width: 26, height: 26)
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color)
                }
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(segment.startTime.clockDisplay)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            Text(segment.text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 34)
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
