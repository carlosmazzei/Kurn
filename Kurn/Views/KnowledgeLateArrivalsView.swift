import KurnCore
import SwiftUI

/// What later recordings revised about an entity's past (K3.5); nothing when
/// nothing arrived late. Words and dates come from `KnowledgeLateArrivalPresentation`.
struct KnowledgeLateArrivalsView: View {
    let page: KnowledgeWikiPage

    var body: some View {
        let items = KnowledgeLateArrivalPresentation.items(page: page)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(KnowledgeLateArrivalPresentation.copy("header")).font(Theme.title3).accessibilityAddTraits(.isHeader)
                Text(KnowledgeLateArrivalPresentation.copy("footer")).font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: item.title).font(Theme.headline)
                        ForEach(Array(item.stretches.enumerated()), id: \.offset) { _, stretch in
                            Text(verbatim: stretch.title).font(Theme.footnoteEmphasized)
                            ForEach(Array(stretch.rows.enumerated()), id: \.offset) { _, row in rowView(row) }
                        }
                    }
                    .padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: KnowledgeComparePresentation.Row) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            if let before = row.before { Text(verbatim: before).font(Theme.footnote).foregroundStyle(Theme.textSecondary) }
            Text(verbatim: row.text).font(Theme.body)
            if !row.notes.isEmpty { Text(verbatim: row.notes.joined(separator: " · ")).font(Theme.captionEmphasized) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let route = row.evidence {
            NavigationLink(value: route) { content }
        } else {
            content
        }
    }
}
