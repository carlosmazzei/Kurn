import Foundation
import KurnCore
import Testing
@testable import Kurn

struct KnowledgeTimelinePresentationTests {
    private static let english = Locale(identifier: "en_US")
    private static let utc = TimeZone(identifier: "UTC")!

    private static func entry(status: String, modality: KnowledgeModality = .reported, stated: KnowledgeTemporalValue?,
                              recordedAt: Date, observedAt: Date? = nil, meetingID: UUID, entityKind: KnowledgeEntityKind = .actionItem,
                              extra: [KnowledgeWikiSnapshot.Fact] = []) throws -> (KnowledgeTimeline, KnowledgeWikiSnapshot.Fact) {
        let entityID = UUID()
        let fact = KnowledgeWikiSnapshot.Fact(id: UUID(), subjectID: entityID, predicate: .hasStatus, value: .enumeration(status),
            qualifiers: .init(modality: modality, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                              confidence: .medium, review: .machineExtracted, validFrom: stated),
            source: .init(meetingID: meetingID, recordedAt: recordedAt, observedAt: observedAt, evidence: [
                .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                      attributedSpeaker: "Speaker 1"),
            ]))
        let wiki = KnowledgeWikiSnapshot(revision: 1, entities: [.init(id: entityID, kind: entityKind, name: "Example runbook")],
                                         facts: [fact])
        return (KnowledgeTimeline.build(pages: try KnowledgeWikiProjector.project(wiki)), fact)
    }

    @Test func aRowKeepsTheStatedPrecisionAndNamesItsMeeting() throws {
        let meetingID = UUID()
        let recorded = try #require(ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z"))
        let stated = try #require(KnowledgeTemporalValue(text: "2026-11", precision: .month))
        let (timeline, fact) = try Self.entry(status: "completed", stated: stated, recordedAt: recorded, meetingID: meetingID)
        let entry = try #require(timeline.periods.first?.entries.first)
        let row = KnowledgeTimelinePresentation.row(entry, meetingTitles: [meetingID: "Example review"], locale: Self.english,
                                                    timeZone: Self.utc)
        #expect(row.stated == String(format: KnowledgeTimelinePresentation.text("stated"), "2026-11"))
        #expect(row.source == String(format: KnowledgeTimelinePresentation.text("recorded_in"), "Example review", "Oct 20, 2026"))
        #expect(row.badges == [KnowledgeTimelinePresentation.text("ahead")])
        #expect(row.evidence == .evidence(assertionID: fact.id, evidenceID: fact.source.evidence[0].id))
        #expect(row.claim == MeetingKnowledgeClaimPresentation.text(entry.item))
        let month = try #require(timeline.periods.first).month
        #expect(KnowledgeTimelinePresentation.monthTitle(month, locale: Self.english) == "November 2026")
    }

    @Test func aRowSaysWhenItWasSaidOnlyWhenThatDiffersFromWhenItWasRecorded() throws {
        let meetingID = UUID()
        let formatter = ISO8601DateFormatter()
        let recorded = try #require(formatter.date(from: "2026-11-14T10:00:00Z"))
        let said = try #require(formatter.date(from: "2026-10-20T13:00:00Z"))
        let stated = try #require(KnowledgeTemporalValue(text: "2026-10", precision: .month))
        let (late, _) = try Self.entry(status: "blocked", stated: stated, recordedAt: recorded, observedAt: said, meetingID: meetingID)
        let lateEntry = try #require(late.periods.first?.entries.first)
        let titled = KnowledgeTimelinePresentation.row(lateEntry, meetingTitles: [meetingID: "Example review"], locale: Self.english,
                                                       timeZone: Self.utc)
        #expect(titled.source == String(format: KnowledgeTimelinePresentation.text("said_in"), "Example review", "Oct 20, 2026", "Nov 14, 2026"))
        let untitled = KnowledgeTimelinePresentation.row(lateEntry, meetingTitles: [:], locale: Self.english, timeZone: Self.utc)
        #expect(untitled.source == String(format: KnowledgeTimelinePresentation.text("said"), "Oct 20, 2026", "Nov 14, 2026"))
        // Said and recorded on one day, at different times: the date is printed once, as before (the days are compared,
        // not the instants).
        let earlierThatDay = try #require(formatter.date(from: "2026-11-14T08:30:00Z"))
        let (sameDay, _) = try Self.entry(status: "blocked", stated: stated, recordedAt: recorded, observedAt: earlierThatDay,
                                          meetingID: meetingID)
        let sameEntry = try #require(sameDay.periods.first?.entries.first)
        let same = KnowledgeTimelinePresentation.row(sameEntry, meetingTitles: [:], locale: Self.english, timeZone: Self.utc)
        #expect(same.source == String(format: KnowledgeTimelinePresentation.text("recorded"), "Nov 14, 2026"))
        for key in ["said", "said_in"] { #expect(KnowledgeTimelinePresentation.text(key) != "knowledge.timeline." + key) }
    }

    @Test func undatedTentativeRowsSayWhatTheyAre() throws {
        let recorded = try #require(ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z"))
        let (timeline, _) = try Self.entry(status: "committed", modality: .hypothetical, stated: nil, recordedAt: recorded,
                                           meetingID: UUID())
        let entry = try #require(timeline.undated.first)
        let row = KnowledgeTimelinePresentation.row(entry, meetingTitles: [:], locale: Self.english, timeZone: Self.utc)
        #expect(row.stated == nil)
        #expect(row.source == String(format: KnowledgeTimelinePresentation.text("recorded"), "Oct 20, 2026"))
        #expect(row.badges == [KnowledgeTimelinePresentation.text("tentative")])
    }

    @Test func lifecycleFindingsAndKindsAreLocalized() throws {
        for kind in KnowledgeTimeline.EntryKind.allCases {
            #expect(KnowledgeTimelinePresentation.kindName(kind) != "knowledge.timeline.kind." + kind.rawValue)
        }
        let codes: [KnowledgeLifecycleProjection.AnomalyCode] = [.invalidTransition, .ambiguousOrder, .unresolvedOrder, .outOfVocabulary]
        for code in codes {
            #expect(KnowledgeTimelinePresentation.text("anomaly." + code.rawValue) != "knowledge.timeline.anomaly." + code.rawValue)
        }
        let month = try #require(KnowledgeTemporalValue(text: "2026-09", precision: .month))
        #expect(KnowledgeTimelinePresentation.monthTitle(month, locale: Locale(identifier: "pt_BR")).contains("2026"))
    }
}
