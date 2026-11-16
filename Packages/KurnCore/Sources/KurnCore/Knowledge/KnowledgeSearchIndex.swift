import Foundation

public enum KnowledgeSearchError: String, Error, Sendable {
    case invalidScope = "knowledge_search_scope_denied"
    case invalidQuery = "knowledge_search_invalid_query"
    case indexLimit = "knowledge_search_index_limit"
}

/// Pure value input shared with the retrieval layer. The embedding flag is a
/// hint, never a capability: the host must still authorize at model admission.
public struct KnowledgeSearchCorpus: Sendable {
    public let pages: [KnowledgeWikiPage]
    public let meetingIDs: Set<UUID>
    public let allowsEmbedding: Bool

    public init(pages: [KnowledgeWikiPage], meetingIDs: Set<UUID>, allowsEmbedding: Bool = false) {
        self.pages = pages
        self.meetingIDs = meetingIDs
        self.allowsEmbedding = allowsEmbedding
    }
}

/// Documents are derivatives, never evidence. Their IDs retain the source
/// type rather than masquerading as transcript chunks with fabricated times.
public struct KnowledgeSearchDocument: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case page, alias, assertion }
    public let id: String
    public let kind: Kind
    public let entityID: UUID
    public let assertionID: UUID?
    public let evidenceID: UUID?
    public let revision: Int
    public let meetingIDs: Set<UUID>
    public let title: String
    public let text: String
    public let displayText: String

    public func snippet(query: String) -> String {
        let normalized = KnowledgeEntityResolver.normalizedName(query)
        let lines = displayText.split(separator: "\n").map(String.init)
        let line = lines.first { KnowledgeEntityResolver.normalizedName($0).contains(normalized) } ?? lines.first ?? title
        return line.count > 240 ? String(line.prefix(240)) + "…" : line
    }
}

/// A disposable, explicitly scoped projection of freshly validated pages.
/// No persistent copy or independent revision pipeline is created. Canonical
/// event documents join this vocabulary with the K3 validated temporal reader.
public struct KnowledgeSearchIndex: Sendable {
    public static let documentLimit = 8_192
    public static let byteLimit = 8_388_608
    public static let queryLimit = 256
    public let documents: [KnowledgeSearchDocument]

    public init(pages: [KnowledgeWikiPage], meetingIDs: Set<UUID>) throws {
        guard !meetingIDs.isEmpty, meetingIDs.count <= 16,
              pages.count <= KnowledgeWikiProjector.entityLimit,
              Set(pages.map(\.entity.id)).count == pages.count,
              Set(pages.map(\.revision)).count <= 1 else { throw KnowledgeSearchError.invalidScope }
        var result: [KnowledgeSearchDocument] = []
        var assertions: [UUID: KnowledgeWikiPage.Entry] = [:]
        var byteCount = 0
        func append(kind: KnowledgeSearchDocument.Kind, id: UUID, page: KnowledgeWikiPage,
                    entries: [KnowledgeWikiPage.Entry], text: String, display: String,
                    evidence: KnowledgeWikiSnapshot.Evidence? = nil) throws {
            let sources = Set(entries.map { $0.fact.source.meetingID })
            guard !sources.isEmpty, sources.isSubset(of: meetingIDs) else { throw KnowledgeSearchError.invalidScope }
            byteCount += text.utf8.count + display.utf8.count + page.entity.name.utf8.count
            guard result.count < Self.documentLimit, byteCount <= Self.byteLimit else { throw KnowledgeSearchError.indexLimit }
            let assertion = kind == .assertion ? entries.first : nil
            let entity = assertion?.subject ?? page.entity
            result.append(KnowledgeSearchDocument(id: kind.rawValue + ":" + id.uuidString.lowercased()
                    + (evidence.map { ":" + $0.id.uuidString.lowercased() } ?? ""), kind: kind,
                entityID: entity.id, assertionID: assertion?.fact.id, evidenceID: evidence?.id,
                revision: page.revision, meetingIDs: sources, title: entity.name, text: text, displayText: display))
        }
        for page in pages.sorted(by: { $0.entity.id.uuidString < $1.entity.id.uuidString }) {
            try Task.checkCancellation()
            let entries = page.sections.flatMap(\.entries)
            guard !entries.isEmpty else { throw KnowledgeSearchError.invalidScope }
            let body = entries.map { Self.text($0) }.joined(separator: "\n")
            let quotes = entries.flatMap { $0.fact.source.evidence.map(\.quote) }.joined(separator: "\n")
            try append(kind: .page, id: page.entity.id, page: page, entries: entries,
                text: ([page.entity.name] + page.entity.aliases + [body]).joined(separator: "\n"), display: quotes)
            if !page.entity.aliases.isEmpty {
                let aliases = page.entity.aliases.joined(separator: "\n")
                try append(kind: .alias, id: page.entity.id, page: page, entries: entries,
                    text: page.entity.name + "\n" + aliases, display: aliases)
            }
            for entry in entries {
                if let previous = assertions[entry.fact.id] {
                    guard previous == entry else { throw KnowledgeSearchError.invalidScope }
                    continue
                }
                guard assertions.count < KnowledgeWikiProjector.factLimit else { throw KnowledgeSearchError.indexLimit }
                assertions[entry.fact.id] = entry
                for evidence in entry.fact.source.evidence {
                    try append(kind: .assertion, id: entry.fact.id, page: page, entries: [entry],
                        text: Self.text(entry, evidence: [evidence]), display: evidence.quote, evidence: evidence)
                }
            }
        }
        documents = result.sorted { $0.id < $1.id }
    }

    public func search(query: String, denseOrder: [Int] = [], limit: Int = 40) throws -> [KnowledgeSearchDocument] {
        guard query.count <= Self.queryLimit, query.utf8.count <= 1_024 else { throw KnowledgeSearchError.invalidQuery }
        let normalized = KnowledgeEntityResolver.normalizedName(query)
        guard !normalized.isEmpty, limit > 0 else { return [] }
        try Task.checkCancellation()
        let texts = documents.map { KnowledgeEntityResolver.normalizedName($0.text) }
        let lexical = HybridSearchRanking.bm25Order(query: normalized, texts: texts)
        let names = documents.indices.filter {
            let doc = documents[$0]
            return doc.kind != .assertion && (KnowledgeEntityResolver.normalizedName(doc.title).contains(normalized)
                || (doc.kind == .alias && KnowledgeEntityResolver.normalizedName(doc.displayText).contains(normalized)))
        }
        let literal = texts.indices.filter { texts[$0].contains(normalized) }
        let dense = denseOrder.filter { documents.indices.contains($0) }
        try Task.checkCancellation()
        let ranked = HybridSearchRanking.reciprocalRankFusion([lexical, names, literal, dense])
        return ranked.prefix(min(limit, 100)).map { documents[$0.index] }
    }

    private static func text(_ entry: KnowledgeWikiPage.Entry, evidence: [KnowledgeWikiSnapshot.Evidence]? = nil) -> String {
        let fact = entry.fact
        let value: String
        switch fact.value {
        case let .string(text), let .enumeration(text): value = text
        case let .number(number, unit): value = String(number) + (unit.map { " " + $0 } ?? "")
        case let .boolean(flag): value = String(flag)
        case let .date(date): value = date.text
        case nil: value = ""
        }
        return [entry.subject.name, fact.predicate.rawValue, entry.object?.name ?? value,
            fact.qualifiers.polarity.rawValue, fact.qualifiers.modality.rawValue, fact.qualifiers.claimKind.rawValue,
            fact.qualifiers.validFrom?.text ?? "", fact.qualifiers.validTo?.text ?? "",
            (evidence ?? fact.source.evidence).map(\.quote).joined(separator: "\n")].joined(separator: "\n")
    }
}
