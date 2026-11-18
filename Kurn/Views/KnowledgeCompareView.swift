import KurnCore
import SwiftUI

/// An entity's state at the end of two days, side by side (K3.4). Built from
/// the same authorized read as the page it opens from; the comparison itself is
/// `KnowledgeComparePresentation` and KurnCore's `KnowledgeStateComparison`.
struct KnowledgeCompareView: View {
    let page: KnowledgeWikiPage
    let pages: [KnowledgeWikiPage]
    @State private var earlier: Date
    @State private var later = Date()
    @State private var asKnownThen = false

    init(page: KnowledgeWikiPage, pages: [KnowledgeWikiPage], now: Date = Date()) {
        self.page = page
        self.pages = pages
        _earlier = State(initialValue: KnowledgeComparePresentation.defaultEarlierDate(page: page, now: now))
        _later = State(initialValue: now)
    }

    var body: some View {
        let comparison = KnowledgeComparePresentation.compare(entityID: page.entity.id, from: earlier, to: later,
                                                              asKnownThen: asKnownThen, pages: pages)
        List {
            Section {
                DatePicker(KnowledgeComparePresentation.copy("from"), selection: $earlier, displayedComponents: .date)
                    .accessibilityIdentifier("knowledge.compare.from")
                DatePicker(KnowledgeComparePresentation.copy("to"), selection: $later, displayedComponents: .date)
                    .accessibilityIdentifier("knowledge.compare.to")
                Toggle(KnowledgeComparePresentation.copy("as_known_then"), isOn: $asKnownThen)
                    .accessibilityIdentifier("knowledge.compare.asKnownThen")
            } footer: {
                Text(KnowledgeComparePresentation.copy(asKnownThen ? "as_known_then_footer" : "as_known_now_footer"))
            }
            if let comparison {
                let sections = KnowledgeComparePresentation.sections(comparison, pages: pages)
                if sections.isEmpty {
                    Text(KnowledgeComparePresentation.copy("empty")).foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("knowledge.compare.empty")
                }
                ForEach(sections, id: \.kind) { section in
                    Section {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in rowView(row) }
                    } header: {
                        Text(section.title).accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .accessibilityIdentifier("knowledge.compare")
    }

    @ViewBuilder
    private func rowView(_ row: KnowledgeComparePresentation.Row) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            if let before = row.before {
                Text(verbatim: before).font(Theme.footnote).foregroundStyle(Theme.textSecondary)
            }
            Text(verbatim: row.text).font(Theme.bodyEmphasized)
            if !row.notes.isEmpty {
                Text(verbatim: row.notes.joined(separator: " · ")).font(Theme.captionEmphasized)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let route = row.evidence {
            NavigationLink(value: route) { content }
                .accessibilityIdentifier("knowledge.compare.change")
        } else {
            content.accessibilityIdentifier("knowledge.compare.change")
        }
    }
}
