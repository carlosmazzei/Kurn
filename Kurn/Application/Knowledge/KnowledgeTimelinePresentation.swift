import Foundation
import KurnCore

/// Words and links for the K3.3 timeline (CLAUDE.md "Knowledge timeline (K3.3)").
/// A month is named from the stated month in UTC, the date a claim states is shown
/// at its own precision (never given a day it did not state), and the meeting it
/// was said in is shown beside it, never used to place it.
enum KnowledgeTimelinePresentation {
    struct Row: Equatable {
        let claim: String
        /// "Stated for …" or nil for an undated claim.
        let stated: String?
        let source: String
        let badges: [String]
        /// The claim's first cited passage; every projected claim has one.
        let evidence: KnowledgeBrowserRoute?
    }

    static func row(_ entry: KnowledgeTimeline.Entry, meetingTitles: [UUID: String], locale: Locale = .current,
                    timeZone: TimeZone = .current) -> Row {
        Row(claim: MeetingKnowledgeClaimPresentation.text(entry.item),
            stated: entry.stated.map { String(format: text("stated"), $0.text) },
            source: source(entry, meetingTitles: meetingTitles, locale: locale, timeZone: timeZone),
            badges: badges(entry),
            evidence: entry.item.fact.source.evidence.first.map {
                .evidence(assertionID: entry.factID, evidenceID: $0.id)
            })
    }

    /// The month's name in `locale`, read in UTC like the stated month itself.
    static func monthTitle(_ month: KnowledgeTemporalValue, locale: Locale = .current) -> String {
        guard let lower = month.bounds?.lower else { return month.text }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: lower)
    }

    static func source(_ entry: KnowledgeTimeline.Entry, meetingTitles: [UUID: String], locale: Locale = .current,
                       timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let date = formatter.string(from: entry.recordedAt)
        guard let title = meetingTitles[entry.item.fact.source.meetingID] else { return String(format: text("recorded"), date) }
        return String(format: text("recorded_in"), title, date)
    }

    /// Tentative, planned-ahead and lifecycle findings, in that order.
    static func badges(_ entry: KnowledgeTimeline.Entry) -> [String] {
        var badges: [String] = []
        if entry.isTentative { badges.append(text("tentative")) }
        if entry.isAhead { badges.append(text("ahead")) }
        badges += entry.lifecycleAnomalies.map { text("anomaly." + $0.rawValue) }
        return badges
    }

    static func kindName(_ kind: KnowledgeTimeline.EntryKind) -> String { text("kind." + kind.rawValue) }

    static func text(_ key: String) -> String {
        NSLocalizedString("knowledge.timeline." + key, comment: "Knowledge timeline")
    }
}
