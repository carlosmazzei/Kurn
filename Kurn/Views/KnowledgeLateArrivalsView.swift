import KurnCore
import SwiftUI

/// What later recordings revised about an entity's past (K3.5); nothing when
/// nothing arrived late. Words and dates come from `KnowledgeLateArrivalPresentation`.
struct KnowledgeLateArrivalsView: View {
    let page: KnowledgeWikiPage

    var body: some View {
        let items = KnowledgeLateArrivalPresentation.items(page: page)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                KnowledgeSectionLabel(KnowledgeLateArrivalPresentation.copy("header")).padding(.top, 4)
                Text(KnowledgeLateArrivalPresentation.copy("footer"))
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: item.title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                        ForEach(Array(item.stretches.enumerated()), id: \.offset) { _, stretch in
                            Text(verbatim: stretch.title).font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
                            ForEach(Array(stretch.rows.enumerated()), id: \.offset) { _, row in KnowledgeChangeRow(row: row) }
                        }
                    }
                    .knowledgeCard()
                }
            }
        }
    }
}

/// One change line shared by the comparison and late-arrival views: what it
/// was before, what it is, its notes, and the passage it opens when cited.
struct KnowledgeChangeRow: View {
    let row: KnowledgeComparePresentation.Row
    var identifier: String?

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            if let before = row.before {
                Text(verbatim: before).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            }
            Text(verbatim: row.text).font(Theme.subheadlineEmphasized).foregroundStyle(Theme.textPrimary)
            if !row.notes.isEmpty {
                Text(verbatim: row.notes.joined(separator: " · ")).font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let route = row.evidence {
            NavigationLink(value: route) {
                HStack(spacing: 12) {
                    content
                    KnowledgeChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier ?? "knowledge.change")
        } else {
            content.accessibilityIdentifier(identifier ?? "knowledge.change")
        }
    }
}
