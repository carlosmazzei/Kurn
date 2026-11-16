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
        case .limited:
            ContentUnavailableView(KnowledgeBrowserCopy.text("search_limit_title"), systemImage: "magnifyingglass",
                description: Text(KnowledgeBrowserCopy.text("search_limit_detail")))
        case .unavailable:
            KnowledgeBrowserUnavailable()
        case let .loaded(hits):
            if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    Section {
                        ForEach(hits) { document in resultRow(document) }
                    } header: {
                        Text(String(format: KnowledgeBrowserCopy.text("scope"), scopeCount))
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("knowledge.search.results")
            }
        }
    }

    private func resultRow(_ document: KnowledgeSearchDocument) -> some View {
        NavigationLink(value: route(document)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: document.title).font(Theme.headline)
                Text(KnowledgeBrowserCopy.text("search_" + document.kind.rawValue))
                    .font(Theme.caption).foregroundStyle(.secondary)
                Text(verbatim: document.snippet(query: query)).font(Theme.subheadline).lineLimit(3)
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
