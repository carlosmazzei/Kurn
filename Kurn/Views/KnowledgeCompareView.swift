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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    DatePicker(KnowledgeComparePresentation.copy("from"), selection: $earlier, displayedComponents: .date)
                        .accessibilityIdentifier("knowledge.compare.from")
                    Divider().overlay(Theme.separator).accessibilityHidden(true)
                    DatePicker(KnowledgeComparePresentation.copy("to"), selection: $later, displayedComponents: .date)
                        .accessibilityIdentifier("knowledge.compare.to")
                    Divider().overlay(Theme.separator).accessibilityHidden(true)
                    Toggle(KnowledgeComparePresentation.copy("as_known_then"), isOn: $asKnownThen)
                        .accessibilityIdentifier("knowledge.compare.asKnownThen")
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .font(Theme.subheadline)
                .knowledgeGroup()
                Text(KnowledgeComparePresentation.copy(asKnownThen ? "as_known_then_footer" : "as_known_now_footer"))
                    .font(Theme.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let comparison {
                    let sections = KnowledgeComparePresentation.sections(comparison, pages: pages)
                    if sections.isEmpty {
                        Text(KnowledgeComparePresentation.copy("empty"))
                            .font(Theme.subheadline).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.top, 16)
                            .accessibilityIdentifier("knowledge.compare.empty")
                    }
                    ForEach(sections, id: \.kind) { section in
                        KnowledgeSectionLabel(section.title).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                                if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 14).accessibilityHidden(true) }
                                KnowledgeChangeRow(row: row, identifier: "knowledge.compare.change")
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                            }
                        }
                        .knowledgeGroup()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }
        .knowledgeReadingSurface()
        .accessibilityIdentifier("knowledge.compare")
    }
}
