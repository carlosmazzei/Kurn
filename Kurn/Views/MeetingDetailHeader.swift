//
//  MeetingDetailHeader.swift
//  Kurn
//
//  The in-content header of the meeting detail screen: full on the Summary
//  tab (title, meta line, participant/folder/tag chips), collapsed to a
//  smaller title on every other tab, so the navigation bar itself stays
//  title-less.
//

import KurnCore
import SwiftUI

struct MeetingDetailHeader: View {
    let meeting: Meeting
    /// Full form (Summary tab) vs collapsed title-only form (other tabs).
    let expanded: Bool
    /// Combined duration of the meeting's recordings.
    let duration: TimeInterval

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 6 : 0) {
            // The user asked for a one-line title like the prototype; AX
            // text sizes get a second line so the label stays readable, and
            // VoiceOver still gets the full title via accessibilityLabel.
            Text(meeting.title)
                .font(.system(expanded ? .title : .title2, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .accessibilityLabel(meeting.title)
            if expanded {
                // Date · time · duration on one line; the language on its
                // own line underneath, so a long name ("Detect
                // automatically") never wraps the whole line.
                Text(metaLine)
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Text((meeting.transcribedLanguage ?? meeting.language).displayName)
                    .font(Theme.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                chips
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, expanded ? 12 : 4)
        .padding(.bottom, expanded ? 14 : 10)
        .kurnAnimation(.easeInOut(duration: 0.2), value: expanded)
    }

    /// "Fri, Nov 21 · 18:28 · 12 min" — duration only when the recordings add
    /// up to something; the language is the line below.
    private var metaLine: String {
        var parts = [
            meeting.createdAt.formatted(Date.FormatStyle().weekday(.abbreviated).month(.abbreviated).day()),
            meeting.createdAt.shortTime
        ]
        if duration > 0, let formatted = Self.durationFormatter.string(from: duration) {
            parts.append(formatted)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var chips: some View {
        let namedSpeakers = meeting.speakers.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if !namedSpeakers.isEmpty || meeting.folder != nil || !meeting.tags.isEmpty {
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(namedSpeakers) { speaker in
                    SpeakerChip(speaker: speaker)
                }
                if let folder = meeting.folder {
                    outlinedChip {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color(hex: folder.colorHex))
                            .accessibilityHidden(true)
                    } label: {
                        Text(folder.name)
                    }
                }
                ForEach(meeting.tags) { tag in
                    outlinedChip {
                        Circle().fill(Color(hex: tag.colorHex)).frame(width: 6, height: 6)
                    } label: {
                        Text(tag.name)
                    }
                }
            }
        }
    }

    private func outlinedChip<Icon: View, Label: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder label: () -> Label
    ) -> some View {
        HStack(spacing: 6) {
            icon()
            label()
        }
        .font(Theme.footnote)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
    }
}

/// A named participant: coloured initial-avatar plus their name on a filled
/// capsule, matching the transcript's speaker colours.
private struct SpeakerChip: View {
    let speaker: Speaker

    var body: some View {
        let color = Color(hex: speaker.color)
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(color.opacity(0.18)).frame(width: 22, height: 22)
                Text(String(speaker.displayName.prefix(1)).uppercased())
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            Text(speaker.displayName)
        }
        .font(Theme.footnote)
        .foregroundStyle(Theme.textPrimary)
        .padding(.trailing, 10)
        .padding(.leading, 3)
        .frame(height: 28)
        .background(Theme.fill, in: Capsule())
    }
}
