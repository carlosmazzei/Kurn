//
//  KnowledgeTimeline.swift
//  KurnCore
//
//  K3.3: the timeline of a scoped knowledge read (CLAUDE.md "Knowledge Engine
//  decisions", ADR-006). A projection of the same authorized, evidence-checked
//  pages the reader shows, never a second store. Each claim is placed by the
//  date it states (valid time) at that date's precision; the meeting it was
//  recorded in is shown beside it, never used to place it. Claims that state
//  no date are kept apart, in recorded order, instead of being given one.
//

import Foundation

public struct KnowledgeTimeline: Equatable, Sendable {
    /// What a claim records about time, for filtering and presentation.
    public enum EntryKind: String, Codable, Sendable, CaseIterable {
        /// A `hasStatus` change.
        case status
        /// A `dueOn` commitment; its value is the due date, its place the date it was stated.
        case dueDate
        /// A `supersedes` replacement.
        case supersession
        /// Any other relation between two entities.
        case relation
        /// Any other value an entity has.
        case attribute
    }

    public struct Entry: Equatable, Sendable {
        public let item: KnowledgeWikiPage.Entry
        public let kind: EntryKind
        /// The stated valid-time start, at its precision; nil in the undated list.
        public let stated: KnowledgeTemporalValue?
        public let recordedAt: Date
        /// When the claim was said (the meeting's date), shown beside `recordedAt`; nil when unknown.
        public let observedAt: Date?
        /// A proposal, hypothesis or disputed claim: shown, never a change of state.
        public let isTentative: Bool
        /// Lifecycle findings (K3.2) about this claim's place in its entity's history.
        public let lifecycleAnomalies: [KnowledgeLifecycleProjection.AnomalyCode]

        public var factID: UUID { item.fact.id }
        /// The stated date lies after the claim was recorded: a plan or a commitment.
        public var isAhead: Bool { stated?.bounds.map { $0.lower > recordedAt } ?? false }
    }

    /// The entries whose stated start falls in one calendar month (UTC).
    public struct Period: Equatable, Sendable {
        public let month: KnowledgeTemporalValue
        public let entries: [Entry]
    }

    public struct Filter: Equatable, Sendable {
        /// Kinds to keep; empty keeps every kind.
        public var kinds: Set<EntryKind>
        public var includesTentative: Bool
        public var includesNegated: Bool

        public init(kinds: Set<EntryKind> = [], includesTentative: Bool = true, includesNegated: Bool = true) {
            self.kinds = kinds
            self.includesTentative = includesTentative
            self.includesNegated = includesNegated
        }

        public var isDefault: Bool { self == Filter() }

        /// Whether entries of `kind` are kept.
        public func shows(_ kind: EntryKind) -> Bool { kinds.isEmpty || kinds.contains(kind) }

        /// This filter with `kind` shown or hidden. Hiding the last kind shown
        /// is refused (an empty set would mean every kind), and showing every
        /// kind again is stored as the empty set.
        public func showing(_ kind: EntryKind, _ shown: Bool) -> Filter {
            var current = kinds.isEmpty ? Set(EntryKind.allCases) : kinds
            if shown { current.insert(kind) } else { current.remove(kind) }
            guard !current.isEmpty else { return self }
            var copy = self
            copy.kinds = current == Set(EntryKind.allCases) ? [] : current
            return copy
        }

        func keeps(_ entry: Entry) -> Bool {
            (kinds.isEmpty || kinds.contains(entry.kind)) && (includesTentative || !entry.isTentative)
                && (includesNegated || entry.item.fact.qualifiers.polarity == .positive)
        }
    }

    public let periods: [Period]
    /// Claims that state no date, oldest recording first.
    public let undated: [Entry]

    public var isEmpty: Bool { periods.isEmpty && undated.isEmpty }

    /// Builds the timeline of `pages`. A claim appearing on several pages (its
    /// subject's and its object's) is one entry. Pure and deterministic.
    public static func build(pages: [KnowledgeWikiPage], filter: Filter = Filter()) -> KnowledgeTimeline {
        var items: [UUID: KnowledgeWikiPage.Entry] = [:]
        var kinds: [UUID: KnowledgeEntityKind] = [:]
        for item in pages.flatMap({ $0.sections.flatMap(\.entries) }) where items[item.fact.id] == nil {
            items[item.fact.id] = item
            // Lifecycles run per stated identity: a claim names its subject (or,
            // for `supersedes`, its object) by its own ID, redirect or not.
            kinds[item.fact.subjectID] = item.subject.kind
            if let objectID = item.fact.objectID, let object = item.object { kinds[objectID] = object.kind }
        }
        let anomalies = lifecycleAnomalies(items: Array(items.values), kinds: kinds)
        let entries = items.values.map { item in
            Entry(item: item, kind: kind(of: item.fact), stated: item.fact.qualifiers.validFrom.flatMap { $0.bounds == nil ? nil : $0 },
                  recordedAt: item.fact.source.recordedAt, observedAt: item.fact.source.observedAt,
                  isTentative: KnowledgeTemporalReducer.tentative.contains(item.fact.qualifiers.modality),
                  lifecycleAnomalies: anomalies[item.fact.id].map { Array($0).sorted { $0.rawValue < $1.rawValue } } ?? [])
        }.filter(filter.keeps)
        var byMonth: [String: (month: KnowledgeTemporalValue, entries: [Entry])] = [:]
        var undated: [Entry] = []
        for entry in entries {
            guard let stated = entry.stated, let month = KnowledgeTemporalValue(
                text: stated.text.prefix(7).description, precision: .month) else {
                undated.append(entry)
                continue
            }
            byMonth[month.text, default: (month, [])].entries.append(entry)
        }
        let periods = byMonth.keys.sorted().compactMap { key in
            byMonth[key].map { Period(month: $0.month, entries: $0.entries.sorted(by: placedBefore)) }
        }
        return KnowledgeTimeline(periods: periods, undated: undated.sorted {
            ($0.recordedAt, $0.factID.uuidString) < ($1.recordedAt, $1.factID.uuidString)
        })
    }

    static func kind(of fact: KnowledgeWikiSnapshot.Fact) -> EntryKind {
        switch fact.predicate {
        case .hasStatus: .status
        case .dueOn: .dueDate
        case .supersedes: .supersession
        default: fact.objectID == nil ? .attribute : .relation
        }
    }

    /// Within a month: by stated start, a narrower period first when two begin
    /// together, then by subject and claim for a stable order.
    private static func placedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let left = lhs.stated?.bounds, right = rhs.stated?.bounds
        let leftName = KnowledgeEntityResolver.normalizedName(lhs.item.subject.name)
        let rightName = KnowledgeEntityResolver.normalizedName(rhs.item.subject.name)
        return (left?.lower ?? .distantPast, left?.upper ?? .distantPast, leftName, lhs.factID.uuidString)
            < (right?.lower ?? .distantPast, right?.upper ?? .distantPast, rightName, rhs.factID.uuidString)
    }

    /// Runs each decision, action and risk's lifecycle over the claims shown and
    /// returns, per claim, the anomaly codes naming it (an `ambiguous` or
    /// `unresolved` order is reported on every claim of its group).
    private static func lifecycleAnomalies(items: [KnowledgeWikiPage.Entry], kinds: [UUID: KnowledgeEntityKind])
        -> [UUID: Set<KnowledgeLifecycleProjection.AnomalyCode>] {
        let claims = items.map { item in
            KnowledgeTemporalClaim(id: item.fact.id, subjectID: item.fact.subjectID, predicate: item.fact.predicate,
                                   objectID: item.fact.objectID, value: item.fact.value, polarity: item.fact.qualifiers.polarity,
                                   modality: item.fact.qualifiers.modality, validFrom: item.fact.qualifiers.validFrom,
                                   validTo: item.fact.qualifiers.validTo, recordedAt: item.fact.source.recordedAt)
        }
        var result: [UUID: Set<KnowledgeLifecycleProjection.AnomalyCode>] = [:]
        for (entityID, kind) in kinds {
            guard let lifecycle = KnowledgeLifecycle(entityKind: kind) else { continue }
            let projection = lifecycle.project(entityID: entityID, knownAt: .distantFuture, claims: claims)
            for anomaly in projection.anomalies {
                for id in anomaly.claimIDs { result[id, default: []].insert(anomaly.code) }
            }
        }
        return result
    }
}
