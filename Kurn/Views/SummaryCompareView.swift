//
//  SummaryCompareView.swift
//  Kurn
//
//  "Compare side by side" from the summary pill menu: the summary on screen
//  against one other, on paper. "Only differences" lists the lines unique to
//  each side grouped by their section titles (`SummaryDiff` runs locally —
//  no AI call); "Everything" shows both summaries' full sections.
//

import KurnCore
import SwiftUI

struct SummaryCompareView: View {
    /// Newest first — same order as the summary pill menu and page dots.
    let summaries: [Summary]
    /// The summary that was on screen when "Compare" was picked; `nil` falls
    /// back to the newest.
    var currentID: UUID? = nil
    let meeting: Meeting

    @Environment(\.dismiss) private var dismiss
    /// The other summary being compared against, by id.
    @State private var otherID: UUID?
    @State private var showDifferencesOnly = true

    private var current: Summary? {
        summaries.first { $0.id == currentID } ?? summaries.first
    }

    private var others: [Summary] {
        summaries.filter { $0.id != current?.id }
    }

    private var other: Summary? {
        others.first { $0.id == otherID } ?? others.first
    }

    private var comparison: SummaryComparison {
        guard let current, let other else {
            return SummaryComparison(onlyInFirst: [], onlyInSecond: [])
        }
        return SummaryDiff.compare(
            first: sectionInputs(of: current),
            second: sectionInputs(of: other)
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if others.count > 1 {
                        Picker(NSLocalizedString("detail.compare.against", comment: "Compare against"),
                               selection: $otherID) {
                            ForEach(others) { summary in
                                Text(title(of: summary)).tag(Optional(summary.id))
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Picker(NSLocalizedString("detail.compare.mode", comment: "Compare mode"),
                           selection: $showDifferencesOnly) {
                        Text(NSLocalizedString("detail.compare.only_differences", comment: "Only differences"))
                            .tag(true)
                        Text(NSLocalizedString("detail.compare.everything", comment: "Everything"))
                            .tag(false)
                    }
                    .pickerStyle(.segmented)

                    if let current, let other {
                        if showDifferencesOnly {
                            differencesBody(current: current, other: other)
                        } else {
                            fullBody(current: current, other: other)
                        }
                    }

                    Text(NSLocalizedString("detail.compare.local_note", comment: "Compared on this device; no AI call"))
                        .font(Theme.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.readingBackground.ignoresSafeArea())
            .navigationTitle(NSLocalizedString("detail.summary.compare", comment: "Compare side by side"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
    }

    /// "Only in <A>" / "Only in <B>", each with its sections and unique lines.
    @ViewBuilder
    private func differencesBody(current: Summary, other: Summary) -> some View {
        let diff = comparison
        if diff.isEmpty {
            ContentUnavailableView {
                Label(
                    NSLocalizedString("detail.compare.no_differences", comment: "No differences"),
                    systemImage: "checkmark.circle"
                )
            }
            .padding(.top, 40)
        } else {
            differenceGroup(
                heading: String(
                    format: NSLocalizedString("detail.compare.only_in", comment: "Only in one summary"),
                    title(of: current)
                ),
                sides: diff.onlyInFirst
            )
            differenceGroup(
                heading: String(
                    format: NSLocalizedString("detail.compare.only_in", comment: "Only in one summary"),
                    title(of: other)
                ),
                sides: diff.onlyInSecond
            )
        }
    }

    private func differenceGroup(heading: String, sides: [SummaryComparison.Side]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading)
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(Array(sides.enumerated()), id: \.offset) { _, side in
                VStack(alignment: .leading, spacing: 6) {
                    if !side.title.isEmpty {
                        Text(side.title)
                            .font(Theme.subheadlineEmphasized)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(side.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(Theme.textTertiary)
                                .font(.system(size: 6))
                                .padding(.top, 7)
                                .accessibilityHidden(true)
                            Text(line)
                                .font(Theme.body)
                                .foregroundStyle(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    /// Both summaries in full, one after the other, each under its name.
    private func fullBody(current: Summary, other: Summary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title(of: current))
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
            SummaryView(summary: current)
            Divider().overlay(Theme.separator)
            Text(title(of: other))
                .font(Theme.headline)
                .foregroundStyle(Theme.textPrimary)
            SummaryView(summary: other)
        }
    }

    /// One summary's sections as `SummaryDiff` input: bullet items plus the
    /// body split into lines, in reading order.
    private func sectionInputs(of summary: Summary) -> [SummaryDiff.SectionInput] {
        summary.sections.map { section in
            let lines = section.items + section.body
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return (title: section.title, lines: lines)
        }
    }

    private func title(of summary: Summary) -> String {
        summary.templateName?.isEmpty == false
            ? summary.templateName!
            : NSLocalizedString("detail.summary.untitled", comment: "Summary")
    }
}
