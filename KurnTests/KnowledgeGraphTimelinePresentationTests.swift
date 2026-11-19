import Foundation
import KurnCore
import Testing
@testable import Kurn

/// K4.3: the Graph Explorer's evolution and compare modes.
@MainActor
struct KnowledgeGraphTimelinePresentationTests {
    private typealias Presentation = KnowledgeGraphPresentation
    private static let meeting = UUID(), project = UUID(), team = UUID(), vendor = UUID()
    private static let blocker = UUID(), dependency = UUID()

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text + "T12:00:00Z"))
    }

    private static func read() throws -> KnowledgeBrowserRead {
        func fact(_ id: UUID, _ subject: UUID, _ predicate: KnowledgePredicate, _ object: UUID, from: String,
                  to: String? = nil) -> KnowledgeWikiSnapshot.Fact {
            KnowledgeWikiSnapshot.Fact(
                id: id, subjectID: subject, predicate: predicate, objectID: object,
                qualifiers: .init(modality: .reported, polarity: .positive, claimKind: .internalStatusReport, authority: .attributed,
                                  confidence: .medium, review: .machineExtracted,
                                  validFrom: KnowledgeTemporalValue(text: from, precision: .day),
                                  validTo: to.flatMap { KnowledgeTemporalValue(text: $0, precision: .day) }),
                source: .init(meetingID: meeting, recordedAt: Date(timeIntervalSince1970: 1_700_000_000), evidence: [
                    .init(id: UUID(), recordingID: UUID(), segmentIDs: ["s1"], quote: "quoted", startMs: 0, endMs: 500,
                          attributedSpeaker: "Speaker 1"),
                ]))
        }
        let entities: [KnowledgeWikiSnapshot.Entity] = [
            .init(id: project, kind: .project, name: "Portal"), .init(id: team, kind: .team, name: "Platform"),
            .init(id: vendor, kind: .organization, name: "Vendor"),
        ]
        let facts = [fact(blocker, team, .blocks, project, from: "2026-02-01"),
                     fact(dependency, project, .dependsOn, vendor, from: "2026-01-01", to: "2026-03-01")]
        return try KnowledgeBrowserRead(meetingIDs: [meeting], wiki: .init(revision: 1, entities: entities, facts: facts),
                                        meetingTitles: [meeting: "Weekly"], policyRevisionKey: "p1")
    }

    private static func scene(_ exploration: Presentation.Exploration, now: Date) throws -> Presentation.Scene {
        let read = try read()
        let laidOut = try #require(KnowledgeGraphQueryService().laidOut(exploration.options.query(root: project), in: read))
        let days = Presentation.days(exploration, pages: read.pages, entityID: project, now: now)
        let states = Presentation.states(exploration, graph: laidOut.graph, pages: read.pages, days: days, calendar: utc)
        return Presentation.scene(laidOut.graph, layout: laidOut.layout, pages: read.pages, states: states)
    }

    @Test func allModeShowsEveryRelationshipWithNoState() throws {
        let scene = try Self.scene(.init(root: Self.project), now: try Self.date("2026-05-01"))
        #expect(Set(scene.edges.map(\.factID)) == [Self.blocker, Self.dependency])
        #expect(scene.edges.allSatisfy { $0.state == nil })
        #expect(Presentation.legend(.relationships) == nil)
    }

    @Test func evolutionShowsWhatHeldOnTheDay() throws {
        var exploration = Presentation.Exploration(root: Self.project)
        exploration.mode = .evolution
        exploration.day = try Self.date("2026-02-15")
        let february = try Self.scene(exploration, now: try Self.date("2026-05-01"))
        #expect(Set(february.edges.map(\.factID)) == [Self.blocker, Self.dependency])
        #expect(february.edges.allSatisfy { $0.state == .holds(.definite) && Presentation.notes($0).isEmpty })
        exploration.day = try Self.date("2026-04-15")
        let april = try Self.scene(exploration, now: try Self.date("2026-05-01"))
        #expect(april.edges.map(\.factID) == [Self.blocker])
        // The node stays where it was; only its relationship is gone.
        #expect(april.nodes.count == 3 && april.edges(touching: Self.vendor).isEmpty)
        // On the day it was stated, a day's precision leaves it only possible.
        exploration.day = try Self.date("2026-02-01")
        let firstDay = try #require(try Self.scene(exploration, now: try Self.date("2026-05-01")).edges.first { $0.factID == Self.blocker })
        #expect(firstDay.state == .holds(.possible) && Presentation.notes(firstDay) == [Presentation.copy("state.possible")])
        #expect(firstDay.state?.isUncertain == true)
        // Before anything was stated, nothing is shown.
        exploration.day = try Self.date("2025-12-01")
        #expect(try Self.scene(exploration, now: try Self.date("2026-05-01")).edges.isEmpty)
        #expect(Presentation.legend(.evolution) == Presentation.copy("mode.evolution.footer"))
    }

    @Test func compareMarksWhatStartedEndedOrHeld() throws {
        var exploration = Presentation.Exploration(root: Self.project)
        exploration.mode = .compare
        exploration.from = try Self.date("2026-01-15")
        exploration.to = try Self.date("2026-04-15")
        let scene = try Self.scene(exploration, now: try Self.date("2026-05-01"))
        let states = Dictionary(uniqueKeysWithValues: scene.edges.map { ($0.factID, $0.state) })
        #expect(states == [Self.blocker: .started(.definite), Self.dependency: .ended(.definite)])
        // The days may be picked in either order.
        (exploration.from, exploration.to) = (exploration.to, exploration.from)
        let swapped = try Self.scene(exploration, now: try Self.date("2026-05-01"))
        #expect(Dictionary(uniqueKeysWithValues: swapped.edges.map { ($0.factID, $0.state) }) == states)
        exploration.from = try Self.date("2026-02-15")
        exploration.to = try Self.date("2026-02-20")
        let kept = try Self.scene(exploration, now: try Self.date("2026-05-01"))
        #expect(kept.edges.allSatisfy { $0.state == .kept(before: .definite, after: .definite) })
        #expect(Presentation.notes(for: .kept(before: .definite, after: .definite)) == [Presentation.copy("state.kept")])
        #expect(Presentation.notes(for: .started(.definite)) == [Presentation.copy("state.started")])
        #expect(Presentation.notes(for: .ended(.definite)) == [Presentation.copy("state.ended")])
        #expect(Presentation.notes(for: .holds(.definite)).isEmpty && Presentation.notes(for: nil).isEmpty)
        #expect(Presentation.legend(.compare) == Presentation.copy("mode.compare.footer"))
    }

    @Test func daysDefaultToTodayAndTheFirstStatedStart() throws {
        let read = try Self.read()
        let now = try Self.date("2026-05-01")
        var exploration = Presentation.Exploration(root: Self.project)
        let defaults = Presentation.days(exploration, pages: read.pages, entityID: Self.project, now: now)
        #expect(defaults.day == now && defaults.to == now)
        let firstStart = try #require(KnowledgeTemporalValue(text: "2026-01-01", precision: .day)?.bounds?.lower)
        #expect(defaults.from == firstStart)
        // An entity without a page falls back to a month before.
        let unknown = Presentation.days(exploration, pages: read.pages, entityID: UUID(), now: now)
        #expect(unknown.from == now.addingTimeInterval(-30 * 86_400))
        let day = try Self.date("2026-02-02"), from = try Self.date("2026-02-03"), to = try Self.date("2026-02-04")
        exploration.day = day
        exploration.from = from
        exploration.to = to
        let chosen = Presentation.days(exploration, pages: read.pages, entityID: Self.project, now: now)
        #expect(chosen == .init(day: day, from: from, to: to))
        // As known then, the point's transaction time is the end of the day, not "now".
        let then = try #require(Presentation.point(day, asKnownThen: true, calendar: Self.utc))
        let current = try #require(Presentation.point(day, asKnownThen: false, calendar: Self.utc))
        #expect(then.knownAt < current.knownAt && then.validAt == current.validAt)
        #expect(Presentation.GraphMode.allCases.map(\.displayName).allSatisfy { !$0.isEmpty })
    }

    @Test func compareKeepsWhatOnlyPossiblyHeld() throws {
        var exploration = Presentation.Exploration(root: Self.project)
        exploration.mode = .compare
        // The blocker was stated for Feb 1: only possibly held at the end of that day.
        exploration.from = try Self.date("2026-02-01")
        exploration.to = try Self.date("2026-02-20")
        let scene = try Self.scene(exploration, now: try Self.date("2026-05-01"))
        let blocker = try #require(scene.edges.first { $0.factID == Self.blocker })
        #expect(blocker.state == .kept(before: .possible, after: .definite))
        #expect(blocker.state?.isUncertain == true)
        #expect(Presentation.notes(blocker) == [Presentation.copy("state.kept"), Presentation.copy("state.uncertain")])
        // Starting on a day it only possibly held is noted as both.
        exploration.from = try Self.date("2026-01-20")
        exploration.to = try Self.date("2026-02-01")
        let started = try #require(try Self.scene(exploration, now: try Self.date("2026-05-01")).edges.first { $0.factID == Self.blocker })
        #expect(started.state == .started(.possible))
        #expect(Presentation.notes(for: started.state) == [Presentation.copy("state.started"), Presentation.copy("state.uncertain")])
        #expect(Presentation.notes(for: .ended(.possible)) == [Presentation.copy("state.ended"), Presentation.copy("state.uncertain")])
        #expect(!Presentation.EdgeState.kept(before: .definite, after: .definite).isUncertain)
    }
}
