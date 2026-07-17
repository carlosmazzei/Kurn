//
//  MarkdownText.swift
//  Kurn
//
//  SwiftUI renderer for the blocks `MarkdownBlockParser` produces: headings
//  (H1–H6), nested/task/ordered lists, blockquotes, fenced code, simple GFM
//  tables, rules, and paragraphs. Still avoids a third-party dependency —
//  inline styling (bold/italic/links/code spans) goes through Foundation's
//  `AttributedString(markdown:)`.
//

import SwiftUI

struct MarkdownText: View {
    private let blocks: [MarkdownBlock]

    init(_ raw: String) {
        blocks = MarkdownBlockParser.parse(raw)
    }

    var body: some View {
        MarkdownBlocksView(blocks: blocks)
    }
}

/// Renders a block list; split from `MarkdownText` so blockquotes can recurse
/// into their inner blocks.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .paragraph(let text):
            markdownInlineText(text)
        case .list(let items):
            listView(items)
        case .blockquote(let inner):
            blockquoteView(inner)
        case .codeBlock(_, let code):
            codeView(code)
        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)
        case .horizontalRule:
            Divider()
        }
    }

    private func headingView(level: Int, text: String) -> some View {
        markdownInlineText(text).font(headingFont(level: level))
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .subheadline.bold()
        case 4: return .subheadline.weight(.semibold)
        case 5: return .footnote.bold()
        default: return .footnote.weight(.semibold)
        }
    }

    private func listView(_ items: [MarkdownListItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                listRow(item)
            }
        }
    }

    @ViewBuilder
    private func listRow(_ item: MarkdownListItem) -> some View {
        Group {
            switch item.marker {
            case .task(let checked):
                MarkdownTaskRow(checked: checked, text: item.text)
            case .bullet:
                HStack(alignment: .top, spacing: 6) {
                    Text(bulletGlyph(for: item.indent))
                    markdownInlineText(item.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .ordered(let number):
                HStack(alignment: .top, spacing: 6) {
                    Text("\(number).")
                        .foregroundStyle(Theme.textSecondary)
                    markdownInlineText(item.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, CGFloat(item.indent) * 12)
    }

    private func bulletGlyph(for indent: Int) -> String {
        switch indent % 3 {
        case 1: return "◦"
        case 2: return "▪"
        default: return "•"
        }
    }

    private func blockquoteView(_ inner: [MarkdownBlock]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.separator)
                .frame(width: 3)
            MarkdownBlocksView(blocks: inner)
                .foregroundStyle(Theme.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func codeView(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        markdownInlineText(header)
                            .font(.subheadline.bold())
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            markdownInlineText(cell)
                                .font(.subheadline)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Non-interactive task checkbox row (`- [ ]` / `- [x]`), shared between the
/// block renderer and `SummaryView`'s section items.
struct MarkdownTaskRow: View {
    let checked: Bool
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: checked ? "checkmark.square" : "square")
                .foregroundStyle(checked ? Theme.accent : Theme.textSecondary)
                .font(.subheadline)
                .padding(.top, 2)
                .accessibilityLabel(accessibilityLabel)
            markdownInlineText(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var accessibilityLabel: Text {
        Text(
            checked
                ? NSLocalizedString("markdown.task.checked", comment: "Checked task accessibility label")
                : NSLocalizedString("markdown.task.unchecked", comment: "Unchecked task accessibility label")
        )
    }
}

/// Render inline Markdown for any summary text, falling back to plain text when
/// a provider returns malformed Markdown.
func markdownInlineText(_ text: String) -> Text {
    if let attributed = try? AttributedString(markdown: text) {
        return Text(attributed)
    }
    return Text(text)
}
