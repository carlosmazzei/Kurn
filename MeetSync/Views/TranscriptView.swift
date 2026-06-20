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
        let color = Color(hex: speaker?.color ?? "#888888")
        let isActive = activeTime.map { $0 >= segment.startTime && $0 < segment.endTime } ?? false

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(speaker?.displayName ?? segment.speakerLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Spacer()
                Text(segment.startTime.clockDisplay)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            (isActive ? color.opacity(0.12) : Color(.secondarySystemBackground)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isActive ? color : .clear, lineWidth: 1.5)
        )
    }
}
