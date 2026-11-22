//
//  MeetingDetailSummaryBar.swift
//  Kurn
//
//  The Summary tab's top bar: an ink-toned pill menu naming the selected
//  summary (and housing every per-summary action), a "Listen" ghost button,
//  and page dots when more than one summary exists.
//

import KurnCore
import SwiftUI

struct MeetingDetailSummaryBar: View {
    let meeting: Meeting
    /// Newest first — the order the page dots and the pill menu use.
    let summaries: [Summary]
    /// Shown while a summary is being written instead of the menu.
    let isSummarizing: Bool
    /// Template name of the in-flight request, for "<template> · writing…".
    let generatingTitle: String
    let onSelectSummary: (Summary) -> Void
    let onGenerate: () -> Void
    let onCompare: () -> Void
    let onTranslateSummary: (Summary) -> Void
    let onCopySummary: (Summary) -> Void
    let onShare: () -> Void
    let onDeleteSummary: (Summary) -> Void
    let onCancel: () -> Void
    let onListen: () -> Void

    @Environment(AppSettings.self) private var settings

    private var selected: Summary? {
        summaries.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if isSummarizing {
                    pillLabel(title: "\(generatingTitle) · \(NSLocalizedString("detail.summary.writing", comment: "writing…"))")
                    Spacer(minLength: 0)
                    cancelGhost
                } else if let selected {
                    summaryMenu(selected: selected)
                    Spacer(minLength: 0)
                    listenGhost
                }
            }
            .frame(minHeight: 44)

            if summaries.count > 1, let selected {
                pageDots(selected: selected)
            }
        }
    }

    private func pillLabel(title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(.caption2, weight: .semibold))
                .accessibilityHidden(true)
        }
        .font(Theme.footnoteEmphasized)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
        .background(Theme.fill, in: Capsule())
        .accessibilityIdentifier("detail.summary.pill")
    }

    private func summaryMenu(selected: Summary) -> some View {
        Menu {
            Section(NSLocalizedString("detail.summary.of_meeting", comment: "Summaries of this meeting")) {
                ForEach(summaries) { summary in
                    Toggle(isOn: Binding(
                        get: { summary.id == selected.id },
                        set: { _ in onSelectSummary(summary) }
                    )) {
                        Text(summaryTitle(for: summary))
                        Text(summarySubtitle(for: summary))
                    }
                }
            }
            Section {
                Button {
                    onGenerate()
                } label: {
                    Label(NSLocalizedString("detail.summary.new", comment: "New summary"), systemImage: "plus")
                }
                if summaries.count > 1 {
                    Button {
                        onCompare()
                    } label: {
                        Label(NSLocalizedString("detail.summary.compare", comment: "Compare side by side"),
                              systemImage: "rectangle.split.2x1")
                    }
                }
                Button {
                    onTranslateSummary(selected)
                } label: {
                    Label(NSLocalizedString("detail.summary.translate", comment: "Translate"), systemImage: "globe")
                }
                Button {
                    onCopySummary(selected)
                } label: {
                    Label(NSLocalizedString("share.copy", comment: "Copy"), systemImage: "doc.on.doc")
                }
                Button {
                    onShare()
                } label: {
                    Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
                }
            }
            Section {
                Button(role: .destructive) {
                    onDeleteSummary(selected)
                } label: {
                    Label(NSLocalizedString("detail.summary.delete", comment: "Delete this summary"), systemImage: "trash")
                }
            }
        } label: {
            pillLabel(title: pillTitle(for: selected))
        }
    }

    private var listenGhost: some View {
        Button(action: onListen) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .accessibilityHidden(true)
                Text(NSLocalizedString("detail.summary.listen", comment: "Listen"))
            }
            .font(Theme.footnote)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    private var cancelGhost: some View {
        Button(role: .cancel, action: onCancel) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle")
                    .accessibilityHidden(true)
                Text(NSLocalizedString("common.cancel", comment: "Cancel"))
            }
            .font(Theme.footnote)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }

    /// Tappable dots: the swipe the prototype suggested was dropped because a
    /// drag gesture on the summary body competed with the ScrollView and
    /// stopped vertical scrolling; the dots and the pill menu switch instead.
    private func pageDots(selected: Summary) -> some View {
        HStack(spacing: 0) {
            ForEach(summaries) { summary in
                Button { onSelectSummary(summary) } label: {
                    Circle()
                        .fill(summary.id == selected.id ? Theme.ink : Theme.decorationTertiary)
                        .frame(width: 8, height: 8)
                        .frame(minWidth: 24, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(summaryTitle(for: summary))
                .accessibilityAddTraits(summary.id == selected.id ? .isSelected : [])
            }
        }
    }

    /// "<template> · <time>" — the time is short ("18:28"); the date lives in
    /// the menu's subtitle rows where there is room for it.
    private func pillTitle(for summary: Summary) -> String {
        "\(summaryTitle(for: summary)) · \(summary.createdAt.shortTime)"
    }

    private func summaryTitle(for summary: Summary) -> String {
        summary.templateName?.isEmpty == false
            ? summary.templateName!
            : NSLocalizedString("detail.summary.untitled", comment: "Summary")
    }

    private func summarySubtitle(for summary: Summary) -> String {
        let when = Calendar.current.isDateInToday(summary.createdAt)
            ? String(format: NSLocalizedString("detail.summary.today_at", comment: "Today at a time"),
                     summary.createdAt.shortTime)
            : summary.createdAt.meetingDisplay
        let engine = summary.model?.isEmpty == false
            ? summary.model!
            : summary.provider.displayName
        return "\(when) · \(engine)"
    }
}
