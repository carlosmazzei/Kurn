import Foundation

/// The K6.2 export bundle: the authorized Knowledge of the chosen meetings — their entities, every
/// attributed claim with its qualifiers, and the evidence each claim cites — as one JSON document
/// (`kurn.knowledge-export`, schema 1). Encoding is deterministic: items are sorted by ID and keys
/// are sorted, so the same Knowledge always gives the same bytes apart from `exportedAt`.
public struct KnowledgeExportBundle: Codable, Equatable, Sendable {
    public static let formatName = "kurn.knowledge-export"
    public static let schemaVersion = 1

    public struct Meeting: Codable, Equatable, Sendable {
        public let id: UUID
        public let title: String
    }

    public let format: String
    public let schema: Int
    /// The canonical revision the Knowledge was read at.
    public let revision: Int
    public let exportedAt: Date
    public let meetings: [Meeting]
    public let entities: [KnowledgeWikiSnapshot.Entity]
    public let facts: [KnowledgeWikiSnapshot.Fact]

    public init(revision: Int, exportedAt: Date, meetingTitles: [UUID: String], pages: [KnowledgeWikiPage]) {
        format = Self.formatName
        schema = Self.schemaVersion
        self.revision = revision
        self.exportedAt = exportedAt
        meetings = meetingTitles.map { Meeting(id: $0.key, title: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let entries = pages.flatMap { $0.sections.flatMap(\.entries) }
        var entities: [UUID: KnowledgeWikiSnapshot.Entity] = [:]
        for entity in pages.map(\.entity) + entries.flatMap({ [$0.subject] + ($0.object.map { [$0] } ?? []) }) {
            entities[entity.id] = entities[entity.id] ?? entity
        }
        // A claim recorded against a since-merged entity keeps its original ID: export that ID as a
        // redirect (`targetID`) to the entity it resolves to, so every reference in the bundle resolves.
        for entry in entries {
            for (raw, resolved) in [(entry.fact.subjectID, entry.subject), (entry.fact.objectID, entry.object)] {
                guard let raw, let resolved, raw != resolved.id, entities[raw] == nil else { continue }
                entities[raw] = KnowledgeWikiSnapshot.Entity(id: raw, kind: resolved.kind, name: resolved.name, aliases: [],
                                                             targetID: resolved.id)
            }
        }
        self.entities = entities.values.sorted { $0.id.uuidString < $1.id.uuidString }
        var facts: [UUID: KnowledgeWikiSnapshot.Fact] = [:]
        for entry in entries { facts[entry.fact.id] = entry.fact }
        self.facts = facts.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads a bundle of this format and schema only.
    public static func decode(_ data: Data) throws -> KnowledgeExportBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(KnowledgeExportBundle.self, from: data)
        guard bundle.format == formatName, bundle.schema == schemaVersion else { throw KnowledgeExportBundleError.unsupported }
        return bundle
    }
}

public enum KnowledgeExportBundleError: Error, Equatable, Sendable {
    case unsupported
}
