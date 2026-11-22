import Foundation

/// Review hints, never a temporal state or an assertion of which source is true.
/// Input pages have already passed the canonical evidence reader.
public struct KnowledgeReviewHint: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case conflict, uncertainDate }
    public let kind: Kind
    public let assertionIDs: [UUID]
    public var id: String { kind.rawValue + ":" + assertionIDs.map(\.uuidString).joined(separator: ":") }
}

public enum KnowledgeReviewProjection {
    public static let limit = 1_024

    public static func hints(pages: [KnowledgeWikiPage]) throws -> [KnowledgeReviewHint] {
        guard pages.count <= KnowledgeWikiProjector.entityLimit else { throw KnowledgeMaintenanceError.limitExceeded }
        var entries: [UUID: KnowledgeWikiPage.Entry] = [:]
        for entry in pages.flatMap({ $0.sections.flatMap(\.entries) }) {
            if let old = entries[entry.fact.id], old != entry { throw KnowledgeMaintenanceError.invalidInput }
            entries[entry.fact.id] = entry
            guard entries.count <= KnowledgeWikiProjector.factLimit else { throw KnowledgeMaintenanceError.limitExceeded }
        }
        var groups: [ClaimKey: [KnowledgeWikiSnapshot.Fact]] = [:]
        var result: [KnowledgeReviewHint] = []
        for entry in entries.values {
            try Task.checkCancellation()
            let fact = entry.fact
            var dates = [fact.qualifiers.validFrom, fact.qualifiers.validTo].compactMap { $0 }
            if case let .date(date) = fact.value { dates.append(date) }
            if dates.contains(where: { $0.precision == .month }) {
                result.append(.init(kind: .uncertainDate, assertionIDs: [fact.id]))
            }
            let key = ClaimKey(subject: entry.subject.id, predicate: fact.predicate, object: entry.object?.id,
                value: fact.value, modality: fact.qualifiers.modality, claim: fact.qualifiers.claimKind,
                from: fact.qualifiers.validFrom, to: fact.qualifiers.validTo)
            groups[key, default: []].append(fact)
        }
        // Exact opposing polarity in the same stated interval only. Different
        // dates, forecasts and reported values are not a "latest wins" reducer.
        for group in groups.values where Set(group.map { $0.qualifiers.polarity }).count > 1 {
            result.append(.init(kind: .conflict, assertionIDs: group.map(\.id).sorted { $0.uuidString < $1.uuidString }))
        }
        guard result.count <= limit else { throw KnowledgeMaintenanceError.limitExceeded }
        return result.sorted { $0.id < $1.id }
    }

    private struct ClaimKey: Hashable {
        let subject: UUID
        let predicate: KnowledgePredicate
        let object: UUID?
        let value: KnowledgeTypedValue?
        let modality: KnowledgeModality
        let claim: KnowledgeClaimKind
        let from: KnowledgeTemporalValue?
        let to: KnowledgeTemporalValue?
    }
}
