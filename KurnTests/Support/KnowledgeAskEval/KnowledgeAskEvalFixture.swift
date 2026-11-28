import CryptoKit
import Foundation
import KurnCore
@testable import Kurn

/// K7.0: a golden knowledge fixture (`Packages/KurnCore/Tests/KurnCoreTests/Fixtures/knowledge`, synthetic)
/// turned into the authorized read the Ask knowledge tools answer from, plus the plain text the judge
/// and the full-transcript variant need. The fixtures live in KurnCore's test bundle, which this target
/// cannot import, so they are read from the checkout by path (`KnowledgeAskEvalFiles`).
struct KnowledgeAskEvalFixture {
    struct Segment: Decodable, Equatable {
        let id: String
        let speaker: String?
        let startMs: Int
        let endMs: Int
        let text: String
    }

    struct Source: Decodable {
        let id: String
        let context: String
        let organization: String?
        let recordedAt: String
        let ingestedAt: String
        let segments: [Segment]
    }

    struct Entity: Decodable {
        let ref: String
        let kind: String
        let name: String
        let aliases: [String]
    }

    struct Evidence: Decodable {
        let source: String
        let segmentIDs: [String]
        let quote: String
    }

    struct Assertion: Decodable {
        let ref: String
        let subject: String
        let predicate: String
        let object: String?
        let value: KnowledgeTypedValue?
        let modality: String
        let polarity: String
        let claimKind: String
        let validFrom: String?
        let precision: String
        let evidence: [Evidence]
    }

    struct Forbidden: Decodable {
        let segmentIDs: [String]
        let quote: String
        let subject: String
        let predicate: String
        let object: String?
        let value: String?
        let source: String?
        let reason: String
    }

    struct Expected: Decodable {
        let entities: [Entity]
        let assertions: [Assertion]
        let mustNotAssert: [Forbidden]
    }

    let id: String
    let language: String
    let sources: [Source]
    let expected: Expected

    /// The golden file's own fixture ID, resolved to the identities the read uses.
    private let entityIDs: [String: UUID]
    private let sourceIDs: [String: UUID]
    private let factIDs: [String: UUID]

    var meetingIDs: Set<UUID> { Set(sourceIDs.values) }

    /// Every `source/segment` the fixture holds: what the scorer accepts as resolvable.
    var segmentKeys: Set<String> { Set(sources.flatMap { source in source.segments.map { "\(source.id)/\($0.id)" } }) }

    /// The day after the newest recording was compiled: what "today" means to a question about it.
    var today: Date {
        let latest = sources.compactMap { Self.instant($0.ingestedAt) }.max() ?? Date(timeIntervalSince1970: 0)
        return latest.addingTimeInterval(86_400)
    }

    private enum Fault: Error { case unknown(String) }

    private struct Raw: Decodable {
        let id: String
        let language: String
        let sources: [Source]
        let expected: Expected
    }

    init(data: Data) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        id = raw.id
        language = raw.language
        sources = raw.sources
        expected = raw.expected
        entityIDs = Dictionary(uniqueKeysWithValues: raw.expected.entities.map { ($0.ref, Self.uuid("\(raw.id)/entity/\($0.ref)")) })
        sourceIDs = Dictionary(uniqueKeysWithValues: raw.sources.map { ($0.id, Self.uuid("\(raw.id)/source/\($0.id)")) })
        factIDs = Dictionary(uniqueKeysWithValues: raw.expected.assertions.map { ($0.ref, Self.uuid("\(raw.id)/fact/\($0.ref)")) })
    }

    /// A stable identity from a name: the same fixture yields the same IDs on every run and machine.
    static func uuid(_ name: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    static func instant(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

    // MARK: Read

    func snapshot() throws -> KnowledgeWikiSnapshot {
        let entities = try expected.entities.map { entity -> KnowledgeWikiSnapshot.Entity in
            guard let kind = KnowledgeEntityKind(rawValue: entity.kind), let identity = entityIDs[entity.ref] else {
                throw Fault.unknown("entity \(entity.ref)")
            }
            return .init(id: identity, kind: kind, name: entity.name, aliases: entity.aliases)
        }
        let facts = try expected.assertions.map(fact)
        return KnowledgeWikiSnapshot(revision: 1, entities: entities, facts: facts)
    }

    private func fact(_ assertion: Assertion) throws -> KnowledgeWikiSnapshot.Fact {
        guard let subject = entityIDs[assertion.subject], let identity = factIDs[assertion.ref],
              let predicate = KnowledgePredicate(rawValue: assertion.predicate),
              let modality = KnowledgeModality(rawValue: assertion.modality),
              let polarity = KnowledgePolarity(rawValue: assertion.polarity),
              let claimKind = KnowledgeClaimKind(rawValue: assertion.claimKind) else { throw Fault.unknown("assertion \(assertion.ref)") }
        let object = try assertion.object.map { reference -> UUID in
            guard let target = entityIDs[reference] else { throw Fault.unknown("object \(reference)") }
            return target
        }
        let from = assertion.validFrom.flatMap { text in
            KnowledgeTemporalPrecision(rawValue: assertion.precision).flatMap { KnowledgeTemporalValue(text: text, precision: $0) }
        }
        let evidence = try assertion.evidence.map { item -> KnowledgeWikiSnapshot.Evidence in
            guard let source = sources.first(where: { $0.id == item.source }), let recording = sourceIDs[item.source] else {
                throw Fault.unknown("source \(item.source)")
            }
            let cited = source.segments.filter { item.segmentIDs.contains($0.id) }
            return .init(id: Self.uuid("\(id)/evidence/\(assertion.ref)/\(item.source)/\(item.segmentIDs.joined(separator: ","))"),
                         recordingID: recording, segmentIDs: item.segmentIDs, quote: item.quote,
                         startMs: cited.map(\.startMs).min() ?? 0, endMs: cited.map(\.endMs).max() ?? 0,
                         attributedSpeaker: cited.first?.speaker ?? "Speaker")
        }
        guard let first = assertion.evidence.first, let meeting = sourceIDs[first.source],
              let origin = sources.first(where: { $0.id == first.source }) else { throw Fault.unknown("evidence \(assertion.ref)") }
        return .init(id: identity, subjectID: subject, predicate: predicate, objectID: object, value: assertion.value,
                     qualifiers: .init(modality: modality, polarity: polarity, claimKind: claimKind, authority: .attributed,
                                       confidence: .medium, review: .machineExtracted, validFrom: from),
                     source: .init(meetingID: meeting, recordedAt: Self.instant(origin.ingestedAt) ?? today,
                                   observedAt: Self.instant(origin.recordedAt), evidence: evidence))
    }

    func read(selection: KnowledgeEvidenceSelection?) throws -> KnowledgeBrowserRead {
        let wiki = try snapshot()
        var cited: KnowledgeEvidenceRead?
        if let selection {
            let pages = try KnowledgeWikiProjector.project(wiki)
            guard let entry = pages.flatMap({ $0.sections.flatMap(\.entries) }).first(where: { $0.fact.id == selection.assertionID }),
                  let evidence = entry.fact.source.evidence.first(where: { $0.id == selection.evidenceID }) else {
                throw KnowledgeWikiStoreError.scopeDenied
            }
            cited = KnowledgeEvidenceRead(entry: entry, evidence: evidence, meetingTitle: title(of: entry.fact.source.meetingID),
                                          fileName: "synthetic.m4a", transcriptFingerprint: id, segments: [])
        }
        return try KnowledgeBrowserRead(
            meetingIDs: meetingIDs, wiki: wiki,
            meetingTitles: Dictionary(uniqueKeysWithValues: meetingIDs.map { ($0, title(of: $0)) }),
            selectedEvidence: cited, policyRevisionKey: "ask-eval",
            meetingContexts: Dictionary(uniqueKeysWithValues: sources.compactMap { source in
                sourceIDs[source.id].map { meeting in
                    (meeting, KnowledgeBrowserContext(id: Self.uuid("\(id)/context/\(source.id)"),
                                                      kind: KnowledgeContextKind(rawValue: source.context) ?? .unknown,
                                                      name: source.organization ?? source.context))
                }
            }))
    }

    /// What the tools show for a meeting: its fixture ID and the day it was held.
    private func title(of meeting: UUID) -> String {
        guard let source = sources.first(where: { sourceIDs[$0.id] == meeting }) else { return "Meeting" }
        return "\(source.id) (\(source.recordedAt.prefix(10)))"
    }

    // MARK: Text for the judge and the full-transcript variant

    /// Every recording's transcript, one segment per line, labelled `source/segment`.
    var transcriptText: String {
        sources.map { source in
            "Meeting \(source.id), held \(source.recordedAt.prefix(10))"
                + (source.organization.map { " (\($0))" } ?? "") + ":\n"
                + source.segments.map {
                "[\(source.id)/\($0.id) at \(Self.clock($0.startMs))] \($0.speaker ?? "Speaker"): \($0.text)"
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// The moment as the knowledge tools show it (`ChatSourceToolText.duration`, rounded to the nearest second), so a
    /// time the model copies from a tool result finds its segment in the transcript the judge reads.
    static func clock(_ milliseconds: Int) -> String {
        ChatSourceToolText.duration(Double(milliseconds) / 1_000)
    }

    /// The compilation's coverage, as `get_coverage` reads it: every segment examined, every recording current.
    func coverage() -> KnowledgeCoverageRead {
        .init(revision: 1, isComplete: true, meetings: sources.compactMap { source in
            sourceIDs[source.id].map { meeting in
                .init(meetingID: meeting, recordings: [
                    .init(recordingID: meeting, totalSegments: source.segments.count, examinedSegments: source.segments.count,
                          state: .current),
                ], classification: .internal)
            }
        })
    }

    /// Each expected assertion's evidence segments (`source/segment`): a grounded answer cites one for every claim it states.
    func evidenceSegments(for refs: [String]) -> [String: Set<String>] {
        Dictionary(uniqueKeysWithValues: expected.assertions.filter { refs.contains($0.ref) }.map { assertion in
            (assertion.ref, Set(assertion.evidence.flatMap { item in item.segmentIDs.map { "\(item.source)/\($0)" } }))
        })
    }

    private func name(_ reference: String?) -> String {
        reference.flatMap { target in expected.entities.first { $0.ref == target }?.name } ?? "?"
    }

    private static func text(_ value: KnowledgeTypedValue) -> String {
        switch value {
        case .string(let text), .enumeration(let text): text
        case .number(let number, let unit): "\(number)" + (unit.map { " \($0)" } ?? "")
        case .boolean(let flag): flag ? "true" : "false"
        case .date(let date): date.text
        }
    }

    private func described(_ assertion: Assertion) -> String {
        let object = assertion.object.map { name($0) } ?? assertion.value.map(Self.text) ?? ""
        let evidence = assertion.evidence.map { "\($0.source)/\($0.segmentIDs.joined(separator: "+")): \"\($0.quote)\"" }.joined(separator: "; ")
        return "\(assertion.ref): \(name(assertion.subject)) \(assertion.predicate) \(object)"
            + " (\(assertion.polarity), \(assertion.modality)"
            + (assertion.validFrom.map { ", from \($0)" } ?? "") + ") — said at \(evidence)"
    }

    /// The claims the judge may mark as stated: the question's expected ones and the tempting ones.
    func judgeTable(expected refs: [String], forbidden indexes: [Int]) -> String {
        let wanted = expected.assertions.filter { refs.contains($0.ref) }.map(described)
        let tempting = indexes.compactMap { index -> String? in
            guard expected.mustNotAssert.indices.contains(index) else { return nil }
            let item = expected.mustNotAssert[index]
            return "!\(index): \(name(item.subject)) \(item.predicate) \(item.object.map { name($0) } ?? item.value ?? "")"
                + " — NOT supported by the meetings (\(item.reason)); tempting span \(item.source ?? "?")/\(item.segmentIDs.joined(separator: "+")): \"\(item.quote)\""
        }
        return (wanted + tempting).joined(separator: "\n")
    }
}

/// Where the fixture and question files are in the checkout the tests run from.
enum KnowledgeAskEvalFiles {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("Packages/KurnCore/Tests/KurnCoreTests/Fixtures")

    static func fixture(_ name: String) throws -> KnowledgeAskEvalFixture {
        try KnowledgeAskEvalFixture(data: Data(contentsOf: fixtures.appendingPathComponent("knowledge/\(name).json")))
    }

    struct Question: Decodable {
        let id: String
        let fixture: String
        let language: String
        let kind: String
        let question: String
        let expected: [String]
        let forbidden: [Int]
        let mustRefuse: Bool
        let citable: [String]
        let traits: [String]?
        let hops: Int?
    }

    private struct QuestionFile: Decodable { let questions: [Question] }

    static func questions() throws -> [Question] {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("knowledge-questions/questions.json"))
        return try JSONDecoder().decode(QuestionFile.self, from: data).questions
    }
}
