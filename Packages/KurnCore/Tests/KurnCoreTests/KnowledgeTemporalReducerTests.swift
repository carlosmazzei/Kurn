import Foundation
import Testing
@testable import KurnCore

/// K3.1: bitemporal state, exact on the synthetic `pt-provisioning-timeline`
/// fixture (a proposal → decision → revision, a blocker imported weeks late).
struct KnowledgeTemporalReducerTests {
    private typealias Timeline = KnowledgeFixtureTimeline
    private static func date(_ text: String) -> Date { Timeline.date(text) }
    private static func day(_ text: String) -> KnowledgeTemporalValue { Timeline.day(text) }
    private static func timeline() throws -> Timeline { try Timeline.load("pt-provisioning-timeline") }

    private static func statuses(_ state: KnowledgeTemporalState) -> [String] {
        state.holdings.filter { $0.predicate == .hasStatus }.compactMap {
            if case let .enumeration(text) = $0.value { return text + ":" + $0.certainty.rawValue } else { return nil }
        }
    }

    @Test func aStatusFollowsValidTimeNotTheLatestMeeting() throws {
        let line = try Self.timeline()
        let thread = try #require(line.entities["e2"])
        let known = Self.date("2026-12-01")
        let expectations = ["2026-09-09": [String](), "2026-09-15": ["proposed:definite"],
                            "2026-10-01": ["approved:definite"], "2026-11-01": ["revised:definite"]]
        for (moment, status) in expectations {
            let state = KnowledgeTemporalReducer.state(of: thread, validAt: Self.date(moment), knownAt: known, claims: line.claims)
            #expect(Self.statuses(state) == status, "at \(moment)")
            #expect(state.conflicts.isEmpty)
        }
        // A status stated on its day is only possible during that day.
        let sameDay = KnowledgeTemporalReducer.state(of: thread, validAt: Self.date("2026-09-25"), knownAt: known, claims: line.claims)
        #expect(Self.statuses(sameDay) == ["approved:possible", "proposed:possible"])
        // Valid time orders the two, so that is uncertainty, not a conflict.
        #expect(sameDay.conflicts.isEmpty)
    }

    @Test func aLateImportChangesWhatIsKnownOnlyFromItsImport() throws {
        let line = try Self.timeline()
        let project = try #require(line.entities["e1"]), team = try #require(line.entities["e4"])
        let blocker = try #require(line.assertions["a6"])
        let validAt = Self.date("2026-10-25")
        let before = KnowledgeTemporalReducer.state(of: project, validAt: validAt, knownAt: Self.date("2026-11-01"), claims: line.claims)
        #expect(!before.holdings.contains { $0.predicate == .blocks })
        let after = KnowledgeTemporalReducer.state(of: project, validAt: validAt, knownAt: Self.date("2026-11-15"), claims: line.claims)
        let blocked = try #require(after.holdings.first { $0.predicate == .blocks })
        #expect(blocked.direction == .incoming && blocked.otherEntityID == team)
        #expect(blocked.certainty == .definite && blocked.claimIDs == [blocker])
        // The blocking team sees the same claim as its own outgoing relation.
        let teamState = KnowledgeTemporalReducer.state(of: team, validAt: validAt, knownAt: Self.date("2026-11-15"), claims: line.claims)
        #expect(teamState.holdings.map(\.direction) == [.outgoing])
    }

    @Test func theResultDoesNotDependOnInputOrImportOrder() throws {
        let line = try Self.timeline()
        let thread = try #require(line.entities["e2"])
        let known = Self.date("2026-12-01")
        let reference = KnowledgeTemporalReducer.state(of: thread, validAt: Self.date("2026-09-25"), knownAt: known, claims: line.claims)
        for _ in 0..<8 {
            let shuffled = KnowledgeTemporalReducer.state(of: thread, validAt: Self.date("2026-09-25"), knownAt: known,
                                                          claims: line.claims.shuffled())
            #expect(shuffled == reference)
        }
    }

    private func claim(_ status: String, from: KnowledgeTemporalValue?, to: KnowledgeTemporalValue? = nil,
                       polarity: KnowledgePolarity = .positive, modality: KnowledgeModality = .reported, subject: UUID,
                       recordedAt: String = "2026-01-01", retractedAt: String? = nil, id: UUID = UUID()) -> KnowledgeTemporalClaim {
        KnowledgeTemporalClaim(id: id, subjectID: subject, predicate: .hasStatus, value: .enumeration(status), polarity: polarity,
                               modality: modality, validFrom: from, validTo: to, recordedAt: Self.date(recordedAt),
                               retractedAt: retractedAt.map(Self.date))
    }

    @Test func differentValuesThatValidTimeCannotOrderAreAConflictNotAWinner() throws {
        let subject = UUID()
        let month = try #require(KnowledgeTemporalValue(text: "2026-10", precision: .month))
        let open = claim("open", from: month, subject: subject, recordedAt: "2026-12-01")
        let blocked = claim("blocked", from: Self.day("2026-10-15"), subject: subject, recordedAt: "2026-10-16")
        let state = KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-11-05"), knownAt: Self.date("2026-12-31"),
                                                   claims: [open, blocked])
        #expect(Self.statuses(state) == ["blocked:definite", "open:definite"])
        let conflict = try #require(state.conflicts.first)
        #expect(conflict.reason == .unorderedValues && Set(conflict.claimIDs) == [open.id, blocked.id])
    }

    @Test func monthPrecisionIsPossibleInsideTheMonthAndDefiniteAfterIt() throws {
        let subject = UUID()
        let month = try #require(KnowledgeTemporalValue(text: "2026-10", precision: .month))
        let claims = [claim("open", from: month, subject: subject)]
        let known = Self.date("2026-12-31")
        #expect(Self.statuses(KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-09-30"), knownAt: known, claims: claims)).isEmpty)
        #expect(Self.statuses(KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-10-15"), knownAt: known, claims: claims))
            == ["open:possible"])
        #expect(Self.statuses(KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-11-02"), knownAt: known, claims: claims))
            == ["open:definite"])
    }

    @Test func intervalsAreHalfOpenInBothClocks() {
        let subject = UUID()
        let claims = [claim("open", from: Self.day("2026-09-10"), to: Self.day("2026-09-20"), subject: subject,
                            recordedAt: "2026-09-10T12:00:00Z", retractedAt: "2026-10-01T00:00:00Z")]
        let known = Self.date("2026-09-30")
        #expect(Self.statuses(KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-09-18"), knownAt: known, claims: claims))
            == ["open:definite"])
        // The end day is the possible boundary; the day after it is out.
        #expect(Self.statuses(KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-09-20"), knownAt: known, claims: claims))
            == ["open:possible"])
        #expect(Self.statuses(KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-09-21"), knownAt: known, claims: claims)).isEmpty)
        // Known from the instant it was recorded, and no longer at its retraction.
        let moment = Self.date("2026-09-18")
        #expect(KnowledgeTemporalReducer.state(of: subject, validAt: moment, knownAt: Self.date("2026-09-10T12:00:00Z"), claims: claims)
            .holdings.count == 1)
        #expect(KnowledgeTemporalReducer.state(of: subject, validAt: moment, knownAt: Self.date("2026-09-10T11:59:59Z"), claims: claims)
            .holdings.isEmpty)
        #expect(KnowledgeTemporalReducer.state(of: subject, validAt: moment, knownAt: Self.date("2026-10-01T00:00:00Z"), claims: claims)
            .holdings.isEmpty)
    }

    @Test func aLaterNegationDisplacesAndAnUnorderedOneContradicts() throws {
        let subject = UUID()
        let known = Self.date("2026-12-31")
        let approved = claim("approved", from: Self.day("2026-09-10"), subject: subject)
        let withdrawn = claim("approved", from: Self.day("2026-10-01"), polarity: .negative, subject: subject)
        let later = KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-10-05"), knownAt: known, claims: [approved, withdrawn])
        #expect(later.holdings.map(\.polarity) == [.negative] && later.conflicts.isEmpty)
        let sameDay = claim("approved", from: Self.day("2026-09-10"), polarity: .negative, subject: subject)
        let both = KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-09-15"), knownAt: known, claims: [approved, sameDay])
        #expect(both.holdings.count == 2)
        #expect(both.conflicts.map(\.reason) == [.contradictoryPolarity])
    }

    @Test func theSameStatementFromTwoMeetingsIsOneHoldingAndAnUndatedClaimNeverDecides() throws {
        let subject = UUID()
        let known = Self.date("2026-12-31")
        let first = claim("open", from: Self.day("2026-09-10"), subject: subject)
        let again = claim("open", from: Self.day("2026-09-20"), subject: subject)
        let undated = claim("blocked", from: nil, subject: subject)
        let state = KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-10-01"), knownAt: known,
                                                   claims: [again, undated, first])
        let open = try #require(state.holdings.first { $0.value == .enumeration("open") })
        #expect(open.certainty == .definite && Set(open.claimIDs) == [first.id, again.id])
        #expect(open.claimIDs == open.claimIDs.sorted { $0.uuidString < $1.uuidString })
        #expect(state.holdings.first { $0.value == .enumeration("blocked") }?.certainty == .possible)
        #expect(state.conflicts.isEmpty)
    }

    @Test func aLaterHypothesisNeverDisplacesAnEstablishedStatus() throws {
        let subject = UUID()
        let observed = claim("open", from: Self.day("2026-09-01"), modality: .observed, subject: subject)
        let maybe = claim("approved", from: Self.day("2026-10-01"), modality: .hypothetical, subject: subject)
        let state = KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-10-10"), knownAt: Self.date("2026-12-31"),
                                                   claims: [observed, maybe])
        #expect(Self.statuses(state) == ["approved:definite", "open:definite"])
        let hypothesis = try #require(state.holdings.first { $0.value == .enumeration("approved") })
        #expect(hypothesis.isTentative && hypothesis.modalities == [.hypothetical])
        let established = try #require(state.holdings.first { $0.value == .enumeration("open") })
        #expect(!established.isTentative && established.modalities == [.observed])
        #expect(state.conflicts.isEmpty)
    }

    @Test func aTentativeAndAnEstablishedClaimOfOneValueStaySeparate() {
        let subject = UUID()
        let proposed = claim("approved", from: Self.day("2026-09-01"), modality: .proposed, subject: subject)
        let agreed = claim("approved", from: Self.day("2026-09-01"), modality: .agreed, subject: subject)
        let state = KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-09-10"), knownAt: Self.date("2026-12-31"),
                                                   claims: [agreed, proposed])
        #expect(state.holdings.map(\.isTentative) == [false, true])
        #expect(state.holdings.map(\.claimIDs) == [[agreed.id], [proposed.id]])
        #expect(state.conflicts.isEmpty)
    }

    @Test func eachOverlappingPairIsReportedUnderItsOwnReason() {
        let subject = UUID()
        let day = Self.day("2026-10-10")
        let approved = claim("approved", from: day, subject: subject)
        let notApproved = claim("approved", from: day, polarity: .negative, subject: subject)
        let rejected = claim("rejected", from: day, subject: subject)
        let state = KnowledgeTemporalReducer.state(of: subject, validAt: Self.date("2026-10-20"), knownAt: Self.date("2026-12-31"),
                                                   claims: [rejected, notApproved, approved])
        let byReason = Dictionary(uniqueKeysWithValues: state.conflicts.map { ($0.reason, Set($0.claimIDs)) })
        #expect(byReason[.contradictoryPolarity] == [approved.id, notApproved.id])
        #expect(byReason[.unorderedValues] == [approved.id, notApproved.id, rejected.id])
        #expect(state.conflicts.map(\.reason) == [.contradictoryPolarity, .unorderedValues])
    }

    @Test func boundsCoverTheWholeStatedPeriodInUTC() throws {
        let month = try #require(KnowledgeTemporalValue(text: "2028-02", precision: .month)?.bounds)
        #expect(month.lower == Self.date("2028-02-01T00:00:00Z") && month.upper == Self.date("2028-03-01T00:00:00Z"))
        let instant = try #require(KnowledgeTemporalValue(text: "2026-12-31T23:59:59Z", precision: .instant)?.bounds)
        #expect(instant.upper == Self.date("2027-01-01T00:00:00Z"))
    }
}
