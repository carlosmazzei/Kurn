import Foundation
import KurnCore

/// Answers graph queries over one scoped knowledge read (K4.1, CLAUDE.md
/// "Knowledge graph query (K4.1)"). The read is already authorized and
/// evidence-checked; this only indexes its pages once and remembers recent
/// answers, keyed by the canonical revision, the meetings and the policy
/// revision the read was taken under and by the pages themselves: a read can
/// change without a new revision (a corrected transcript drops evidence and,
/// with it, a claim), so nothing is answered from pages other than the read's.
@MainActor
final class KnowledgeGraphQueryService {
    struct GraphScope: Equatable {
        let revision: Int
        let meetingIDs: Set<UUID>
        let policyRevisionKey: String
        let pages: [KnowledgeWikiPage]

        init(_ read: KnowledgeBrowserRead) {
            revision = read.pages.first?.revision ?? -1
            meetingIDs = read.meetingIDs
            policyRevisionKey = read.policyRevisionKey
            pages = read.pages
        }
    }

    /// The most answers kept for one scope; the least recently asked goes first.
    let capacity: Int
    private(set) var scope: GraphScope?
    private var index: KnowledgeGraphIndex?
    private var answers: [KnowledgeGraph.Query: KnowledgeGraph?] = [:]
    private var recency: [KnowledgeGraph.Query] = []
    /// How many times an index was built, for tests.
    private(set) var indexBuilds = 0

    init(capacity: Int = 32) {
        self.capacity = max(capacity, 1)
    }

    /// The neighbourhood `query` asks for in `read`, or nil when its root is
    /// not an identity the read shows.
    func graph(_ query: KnowledgeGraph.Query, in read: KnowledgeBrowserRead) -> KnowledgeGraph? {
        let current = GraphScope(read)
        if current != scope || index == nil {
            scope = current
            index = KnowledgeGraphIndex(pages: read.pages)
            indexBuilds += 1
            answers = [:]
            recency = []
        }
        if let cached = answers[query] {
            touch(query)
            return cached
        }
        let answer = index?.query(query)
        answers[query] = .some(answer)
        touch(query)
        if recency.count > capacity {
            let evicted = recency.removeFirst()
            answers[evicted] = nil
        }
        return answer
    }

    /// Forgets everything, e.g. when the reader closes or its scope is revoked.
    func clear() {
        scope = nil
        index = nil
        answers = [:]
        recency = []
    }

    var cachedAnswerCount: Int { answers.count }

    private func touch(_ query: KnowledgeGraph.Query) {
        recency.removeAll { $0 == query }
        recency.append(query)
    }
}
