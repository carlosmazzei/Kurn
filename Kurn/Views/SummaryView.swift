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
                Text(section.title).font(.headline)
            }
            if !section.body.isEmpty {
                MarkdownText(section.body)
            }
            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 6))
                        .padding(.top, 7)
                    Text(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Minimal block-level Markdown renderer (headings, bullets, paragraphs). Avoids
/// a third-party dependency while handling the shapes the summary prompt yields.
struct MarkdownText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
    }

    private var lines: [String] {
        raw.components(separatedBy: "\n")
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else if trimmed.hasPrefix("### ") {
            Text(String(trimmed.dropFirst(4)))
                .font(.subheadline.bold())
        } else if trimmed.hasPrefix("## ") {
            Text(String(trimmed.dropFirst(3)))
                .font(.title3.bold())
        } else if trimmed.hasPrefix("# ") {
            Text(String(trimmed.dropFirst(2)))
                .font(.title2.bold())
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                inlineText(String(trimmed.dropFirst(2)))
            }
        } else {
            inlineText(trimmed)
        }
    }

    /// Render inline emphasis/bold using AttributedString's markdown parser.
    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }
}
