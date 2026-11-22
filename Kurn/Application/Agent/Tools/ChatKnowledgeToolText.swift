import AgentHarness
import Foundation
import KurnCore

/// Compact, canonical text for the knowledge tools (K5.1), in the form of `ChatSourceToolText`:
/// one line per item, IDs the model passes back, vocabulary raw values rather than localized
/// words, and every name and quote collapsed to one clipped line. Each result ends with a `page:`
/// line and a `revision:` line (ADR-007), never a JSON envelope.
enum ChatKnowledgeToolText {
    typealias Rendered = ChatSourceToolText.Rendered

    static func output(header: String, lines: [Rendered], offset: Int, limit: Int,
                       read: KnowledgeBrowserRead) -> AgentToolOutput {
        output(header: header, lines: lines, offset: offset, limit: limit, scope: (read.revision, read.meetingIDs.count))
    }

    /// `scope` is the revision the read was taken at and how many meetings it covered.
    static func output(header: String, lines: [Rendered], offset: Int, limit: Int,
                       scope: (revision: Int, meetings: Int)) -> AgentToolOutput {
        let page = Array(lines.dropFirst(offset).prefix(limit))
        var count = page.count
        let footer = "revision: \(scope.revision); meetings: \(scope.meetings)"
        func content() -> String {
            let pageLine = ChatSourceToolText.pageLine(offset: offset, count: count, total: lines.count)
            return ([header] + page.prefix(count).map(\.text) + [pageLine, footer]).joined(separator: "\n")
        }
        while count > 1, content().utf8.count > ChatSourceTools.maxOutputBytes { count -= 1 }
        let shown = page.prefix(count)
        let metrics: [AgentDiagnostic.Metric: Int] = [
            .omittedScalars: shown.reduce(0) { $0 + $1.omittedScalars },
            .returnedItems: count, .deferredItems: max(0, lines.count - offset - count),
            .hasMore: offset + count < lines.count ? 1 : 0
        ]
        return AgentToolOutput(content: content(), summary: "Read \(count) knowledge items", metrics: metrics)
    }

    static func hit(_ document: KnowledgeSearchDocument, query: String) -> Rendered {
        let title = ChatSourceToolText.renderedField(document.title, limit: 200)
        let snippet = ChatSourceToolText.renderedField(document.snippet(query: query), limit: 300)
        var line = "- \(document.kind.rawValue) | entity \(document.entityID.uuidString) | \(title.text) | \(snippet.text)"
        if let assertion = document.assertionID { line += " | assertion \(assertion.uuidString)" }
        if let evidence = document.evidenceID { line += " | evidence \(evidence.uuidString)" }
        return Rendered(text: line, omittedScalars: title.omittedScalars + snippet.omittedScalars)
    }

    static func entityHeader(_ page: KnowledgeWikiPage) -> String {
        var line = "entity \(page.entity.id.uuidString) | \(ChatSourceToolText.field(page.entity.name, limit: 200))"
            + " | kind: \(page.entity.kind.rawValue)"
        if !page.entity.aliases.isEmpty {
            line += " | aliases: " + page.entity.aliases.prefix(10).map { ChatSourceToolText.field($0, limit: 100) }.joined(separator: ", ")
        }
        return line + "\nclaims (assertion | claim | qualifiers | meeting | first evidence):"
    }

    static func paragraph(_ paragraph: KnowledgeWikiNarrative.Paragraph, index: Int) -> Rendered {
        let text = ChatSourceToolText.renderedField(paragraph.text, limit: 2_000)
        let cites = paragraph.assertionIDs.map(\.uuidString).joined(separator: ", ")
        return Rendered(text: "- \(index) | \(text.text) | \(cites)", omittedScalars: text.omittedScalars)
    }

    static func claim(_ entry: KnowledgeWikiPage.Entry) -> Rendered {
        let text = ChatSourceToolText.renderedField(claimText(entry), limit: 400)
        var line = "- \(entry.fact.id.uuidString) | \(text.text) | \(qualifiers(entry.fact.qualifiers))"
            + " | meeting \(entry.fact.source.meetingID.uuidString)"
        var omitted = text.omittedScalars
        if let evidence = entry.fact.source.evidence.first {
            let quote = ChatSourceToolText.renderedField(evidence.quote, limit: 300)
            let speaker = ChatSourceToolText.field(evidence.attributedSpeaker, limit: 100)
            line += " | evidence \(evidence.id.uuidString) \(timestamp(evidence.startMs)) \(speaker): \"\(quote.text)\""
            omitted += quote.omittedScalars
        }
        return Rendered(text: line, omittedScalars: omitted)
    }

    static func timeline(_ entry: KnowledgeTimeline.Entry) -> Rendered {
        let text = ChatSourceToolText.renderedField(claimText(entry.item), limit: 400)
        var line = "- \(entry.stated?.text ?? "undated") | \(text.text) | \(qualifiers(entry.item.fact.qualifiers))"
            + " | assertion \(entry.factID.uuidString) | recorded \(ChatSourceToolText.date(entry.recordedAt))"
        if entry.isTentative { line += " | tentative" }
        if !entry.lifecycleAnomalies.isEmpty {
            line += " | anomalies: " + entry.lifecycleAnomalies.map(\.rawValue).joined(separator: ", ")
        }
        return Rendered(text: line, omittedScalars: text.omittedScalars)
    }

    static func evidence(_ read: KnowledgeEvidenceRead) -> Rendered {
        let title = ChatSourceToolText.renderedField(read.meetingTitle, limit: 200)
        let quote = ChatSourceToolText.renderedField(read.evidence.quote, limit: 2000)
        let speaker = ChatSourceToolText.field(read.evidence.attributedSpeaker, limit: 100)
        let line = "meeting \(read.entry.fact.source.meetingID.uuidString) | \(title.text)"
            + " | assertion \(read.entry.fact.id.uuidString) | \(claimText(read.entry)) | \(qualifiers(read.entry.fact.qualifiers))"
            + "\n\(timestamp(read.evidence.startMs))–\(timestamp(read.evidence.endMs)) \(speaker): \"\(quote.text)\""
        return Rendered(text: line, omittedScalars: title.omittedScalars + quote.omittedScalars)
    }

    /// Subject, predicate and object (or value) in the claim's stated direction, `NOT` first when
    /// the claim was explicitly negated.
    static func claimText(_ entry: KnowledgeWikiPage.Entry) -> String {
        let object = entry.object?.name ?? entry.fact.value.map(valueText) ?? ""
        let claim = [entry.subject.name, entry.fact.predicate.rawValue, object].filter { !$0.isEmpty }.joined(separator: " ")
        return entry.fact.qualifiers.polarity == .negative ? "NOT " + claim : claim
    }

    static func valueText(_ value: KnowledgeTypedValue) -> String {
        switch value {
        case let .string(text): text
        case let .number(number, unit): MeetingKnowledgeClaimPresentation.numberText(number, locale: Locale(identifier: "en_US_POSIX"))
            + (unit.map { " " + $0 } ?? "")
        case let .boolean(flag): flag ? "true" : "false"
        case let .date(date): date.text
        case let .enumeration(text): text
        }
    }

    static func qualifiers(_ qualifiers: KnowledgeWikiSnapshot.Qualifiers) -> String {
        var parts = ["modality: \(qualifiers.modality.rawValue)", "kind: \(qualifiers.claimKind.rawValue)",
                     "review: \(qualifiers.review.rawValue)"]
        if let from = qualifiers.validFrom { parts.append("valid from: \(from.text)") }
        if let to = qualifiers.validTo { parts.append("valid to: \(to.text)") }
        return parts.joined(separator: "; ")
    }

    /// Recording-relative, in the transcript's `[m:ss]` form.
    static func timestamp(_ milliseconds: Int) -> String {
        ChatSourceToolText.timestamp(Double(milliseconds) / 1000)
    }
}
