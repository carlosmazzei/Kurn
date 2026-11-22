//
//  SummaryView.swift
//  Kurn
//
//  Renders an AI summary: template-driven sections and a provenance footer
//  (provider + model + timestamp).
//

import KurnCore
import SwiftUI

struct SummaryView: View {
    let summary: Summary
    /// Taps a section's photo reference chip. `nil` hides the chip row
    /// entirely, so a call site that doesn't wire this up (if any is ever
    /// added) doesn't need to pass anything.
    var onShowPhoto: ((TimeInterval) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                sectionBlock(section)
            }

            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .accessibilityHidden(true)
                Text(
                    String(
                        format: summary.model == nil
                            ? NSLocalizedString("summary.footer", comment: "Provider footer")
                            : NSLocalizedString("summary.footer_with_model", comment: "Provider and model footer"),
                        summary.provider.displayName,
                        summary.model ?? summary.updatedAt.meetingDisplay,
                        summary.updatedAt.meetingDisplay
                    )
                )
            }
            .font(Theme.footnote)
            .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func sectionBlock(_ section: SummarySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.title.isEmpty {
                markdownInlineText(section.title)
                    .font(.system(.title3, weight: .bold))
            }
            if !section.body.isEmpty {
                MarkdownText(section.body)
            }
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                itemRow(item)
            }
            photoReferenceChips(section.photoTimestamps)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A row of tappable "see photo" chips — the same shape
    /// `MeetingChatView.timestampChips` uses for its citations, so a photo a
    /// section drew on isn't left as invisible provenance in the prose.
    @ViewBuilder
    private func photoReferenceChips(_ timestamps: [TimeInterval]) -> some View {
        if !timestamps.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(timestamps, id: \.self) { time in
                        Button { onShowPhoto?(time) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "camera.fill").font(.caption2)
                                    .accessibilityHidden(true)
                                Text(time.clockDisplay).font(.system(.caption, design: .default, weight: .medium))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.fill, in: Capsule())
                            .foregroundStyle(Theme.link)
                        }
                        .buttonStyle(.plain)
                        .disabled(onShowPhoto == nil)
                        .accessibilityLabel(String(
                            format: NSLocalizedString("summary.photo_reference", comment: "View photo at time"),
                            time.clockDisplay
                        ))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemRow(_ item: String) -> some View {
        if item.contains("\n") {
            // A model sometimes stuffs an action item's Owner/Deadline/Context
            // onto sub-lines within a single bullet. Render the whole item with
            // the block renderer so those become sub-bullets instead of one run,
            // promoting a leading bare "[ ]"/"[x]" to a "- [ ]" task line so the
            // parser draws the checkbox.
            MarkdownText(Self.asMarkdownBlock(item))
        } else if let task = MarkdownBlockParser.taskItem(in: item) {
            MarkdownTaskRow(checked: task.checked, text: task.text)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(Theme.textTertiary)
                    .font(.system(size: 6))
                    .padding(.top, 7)
                    .accessibilityHidden(true)
                markdownInlineText(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Turn a multi-line item into a markdown list so the block renderer draws a
    /// bullet/checkbox for the first line and nested bullets for the rest. A bare
    /// leading `[ ]`/`[x]` thus becomes `- [ ]`/`- [x]` (a task line); a line that
    /// already starts with a list marker is left as-is.
    private static func asMarkdownBlock(_ item: String) -> String {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "-*+".contains(first) {
            return trimmed
        }
        return "- \(trimmed)"
    }
}
