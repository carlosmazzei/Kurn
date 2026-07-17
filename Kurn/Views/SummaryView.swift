//
//  SummaryView.swift
//  Kurn
//
//  Renders an AI summary: template-driven sections and a provenance footer
//  (provider + model + timestamp).
//

import SwiftUI

struct SummaryView: View {
    let summary: Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                sectionCard(section)
                    .kurnCard()
            }

            if let templateName = summary.templateName, !templateName.isEmpty {
                Text(
                    String(
                        format: NSLocalizedString("summary.template_label", comment: "Template label"),
                        templateName
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

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
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func sectionCard(_ section: SummarySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.title.isEmpty {
                markdownInlineText(section.title)
                    .font(.headline)
            }
            if !section.body.isEmpty {
                MarkdownText(section.body)
            }
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                itemRow(item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func itemRow(_ item: String) -> some View {
        if let task = MarkdownBlockParser.taskItem(in: item) {
            MarkdownTaskRow(checked: task.checked, text: task.text)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 6))
                    .padding(.top, 7)
                markdownInlineText(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
