//
//  SummaryView.swift
//  MeetSync
//
//  Renders an AI summary: markdown body, key decisions, action items, and a
//  provenance footer (provider + timestamp).
//

import SwiftUI

struct SummaryView: View {
    let summary: Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MarkdownText(summary.content)
                .meetsyncCard()

            if !summary.keyDecisions.isEmpty {
                bulletSection(
                    title: NSLocalizedString("summary.key_decisions", comment: "Key Decisions"),
                    items: summary.keyDecisions,
                    symbol: "checkmark.seal.fill",
                    tint: Theme.success
                )
                .meetsyncCard()
            }

            if !summary.actionItems.isEmpty {
                bulletSection(
                    title: NSLocalizedString("summary.action_items", comment: "Action Items"),
                    items: summary.actionItems,
                    symbol: "square",
                    tint: Theme.info
                )
                .meetsyncCard()
            }

            Text(
                String(
                    format: NSLocalizedString("summary.footer", comment: "Provider footer"),
                    summary.provider.displayName,
                    summary.updatedAt.meetingDisplay
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func bulletSection(
        title: String,
        items: [String],
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .font(.body)
                    Text(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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
