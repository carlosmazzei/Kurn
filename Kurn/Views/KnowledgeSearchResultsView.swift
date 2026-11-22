import KurnCore
import SwiftUI

struct KnowledgeSearchResultsView: View {
    let query: String
    let state: KnowledgeSearchState
    let scopeCount: Int

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView(NSLocalizedString("detail.knowledge.loading", comment: "Loading"))
                .accessibilityIdentifier("knowledge.search.loading")
        case .limited:
            ContentUnavailableView(KnowledgeBrowserCopy.text("search_limit_title"), systemImage: "magnifyingglass",
                description: Text(KnowledgeBrowserCopy.text("search_limit_detail")))
        case .unavailable:
            KnowledgeBrowserUnavailable()
        case let .loaded(hits):
            if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        KnowledgeSectionLabel(String(format: KnowledgeBrowserCopy.text("scope"), scopeCount))
                        ForEach([KnowledgeSearchDocument.Kind.page, .alias, .assertion], id: \.self) { kind in
                            let group = hits.filter { $0.kind == kind }
                            if !group.isEmpty {
                                KnowledgeSectionLabel(sectionTitle(kind)).padding(.top, 8)
                                VStack(spacing: 0) {
                                    ForEach(Array(group.enumerated()), id: \.element.id) { index, document in
                                        if index > 0 { Divider().overlay(Theme.separator).padding(.leading, 58).accessibilityHidden(true) }
                                        resultRow(document)
                                    }
                                }
                                .knowledgeGroup()
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("knowledge.search.results")
            }
        }
    }

    private func sectionTitle(_ kind: KnowledgeSearchDocument.Kind) -> String {
        switch kind {
        case .page: KnowledgeBrowserCopy.text("pages")
        case .alias: NSLocalizedString("knowledge.search.aliases", comment: "Alias matches")
        case .assertion: NSLocalizedString("knowledge.entity.facts", comment: "Fact matches")
        }
    }

    private func resultRow(_ document: KnowledgeSearchDocument) -> some View {
        KnowledgeLinkCard(route: route(document)) {
            HStack(alignment: .top, spacing: 12) {
                KnowledgeIconWell(systemImage: document.assertionID == nil ? "book" : "text.quote",
                                  tint: document.assertionID == nil ? Theme.textSecondary : Theme.info)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: document.title).font(Theme.headline).foregroundStyle(Theme.textPrimary)
                    Text(KnowledgeBrowserCopy.text("search_" + document.kind.rawValue))
                        .font(Theme.caption2Emphasized).foregroundStyle(Theme.textSecondary)
                    Text(verbatim: document.snippet(query: query))
                        .font(Theme.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(3)
                }
            }
        }
        .accessibilityIdentifier("knowledge.search.result.\(document.kind.rawValue)")
    }

    private func route(_ document: KnowledgeSearchDocument) -> KnowledgeBrowserRoute {
        if let assertion = document.assertionID, let evidence = document.evidenceID {
            return .evidence(assertionID: assertion, evidenceID: evidence)
        }
        return .entity(document.entityID)
    }
}
