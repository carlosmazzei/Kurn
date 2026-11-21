import Foundation

/// The prompt and parser for a page's generated narrative (K2): the model sees the page's claims as
/// numbered references (`[c1]`, `[c2]`, …) and writes short paragraphs citing them. Parsing keeps
/// only paragraphs that cite at least one of those references, resolves them to assertion IDs and
/// respects the projector's limits, so its output always validates against the page.
public enum KnowledgeNarrativePrompt {
    /// Claims shown to the model; a larger page keeps its most recently recorded ones.
    public static let claimLimit = 40
    static let paragraphLimit = 32
    static let byteLimit = 16_384
    static let paragraphByteLimit = 2_048
    static let citationLimit = 16

    public static let systemPrompt = """
        You write a short encyclopedic summary of one entity from meeting knowledge. Use only the \
        numbered claims given. Write one to four plain-text paragraphs separated by a blank line, no \
        headings, lists or Markdown. End every sentence with the references it relies on, like [c1] or \
        [c2][c3]. Keep each claim's modality, negation and time: a proposed, disputed or negated claim \
        stays proposed, disputed or negated. Do not add facts that are not in the claims. Write in the \
        language of the claims.
        """

    public struct Request: Equatable, Sendable {
        public let userPrompt: String
        /// Reference label (`c1`) to the assertion it stands for.
        public let references: [String: UUID]
    }

    public static func request(_ page: KnowledgeWikiPage) -> Request? {
        let all = page.sections.flatMap(\.entries)
        let kept = Set(all.enumerated().sorted {
            ($0.element.fact.source.recordedAt, $0.offset) > ($1.element.fact.source.recordedAt, $1.offset)
        }.prefix(claimLimit).map(\.offset))
        let entries = all.enumerated().filter { kept.contains($0.offset) }.map(\.element)
        guard !entries.isEmpty else { return nil }
        var references: [String: UUID] = [:]
        var lines = ["Entity: \(page.entity.name) (\(page.entity.kind.rawValue))", "Claims:"]
        for (index, entry) in entries.enumerated() {
            let label = "c\(index + 1)"
            references[label] = entry.fact.id
            let fact = entry.fact
            let object = entry.object?.name ?? fact.value.map { "\($0)" } ?? ""
            var qualifiers = "\(fact.qualifiers.modality.rawValue), \(fact.qualifiers.polarity.rawValue)"
            if let from = fact.qualifiers.validFrom { qualifiers += ", from \(from)" }
            if let to = fact.qualifiers.validTo { qualifiers += ", until \(to)" }
            lines.append("[\(label)] \(entry.subject.name) \(fact.predicate.rawValue) \(object) (\(qualifiers))")
        }
        return Request(userPrompt: lines.joined(separator: "\n"), references: references)
    }

    public static func parse(_ output: String, entityID: UUID, references: [String: UUID]) -> KnowledgeWikiNarrative? {
        guard let pattern = try? NSRegularExpression(pattern: #"\[(c[0-9]+)\]"#) else { return nil }
        var paragraphs: [KnowledgeWikiNarrative.Paragraph] = []
        var bytes = 0
        let blocks = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks where paragraphs.count < paragraphLimit {
            let range = NSRange(block.startIndex..., in: block)
            var cited: [UUID] = []
            for match in pattern.matches(in: block, range: range) {
                guard let labelRange = Range(match.range(at: 1), in: block), let id = references[String(block[labelRange])],
                      !cited.contains(id) else { continue }
                cited.append(id)
            }
            let text = pattern.stringByReplacingMatches(in: block, range: range, withTemplate: "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: " ,", with: ",")
            guard !cited.isEmpty, cited.count <= citationLimit, !text.isEmpty, text.utf8.count <= paragraphByteLimit,
                  bytes + text.utf8.count <= byteLimit else { continue }
            bytes += text.utf8.count
            paragraphs.append(.init(text: text, assertionIDs: cited))
        }
        return paragraphs.isEmpty ? nil : KnowledgeWikiNarrative(entityID: entityID, paragraphs: paragraphs)
    }
}
