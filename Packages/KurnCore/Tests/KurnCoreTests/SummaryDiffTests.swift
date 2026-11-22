//
//  SummaryDiffTests.swift
//  KurnCoreTests
//
//  `SummaryDiff.compare`: identical summaries produce empty sides, unique
//  lines stay grouped under their section title, and matching ignores case,
//  punctuation and whitespace.
//

import Testing
@testable import KurnCore

struct SummaryDiffTests {
    typealias Section = SummaryDiff.SectionInput

    @Test func identicalSummariesProduceNoDifferences() {
        let sections: [Section] = [
            ("Key Decisions", ["Ship offline sync", "Drop legacy import"]),
            ("Action Items", ["Sam writes the doc"])
        ]
        let diff = SummaryDiff.compare(first: sections, second: sections)
        #expect(diff.isEmpty)
        #expect(diff.onlyInFirst.isEmpty)
        #expect(diff.onlyInSecond.isEmpty)
    }

    @Test func extraBulletAppearsOnlyOnItsSide() {
        let first: [Section] = [("Decisions", ["Ship sync", "Keep web app"])]
        let second: [Section] = [("Decisions", ["Ship sync"])]
        let diff = SummaryDiff.compare(first: first, second: second)
        #expect(diff.onlyInFirst.count == 1)
        #expect(diff.onlyInFirst.first?.title == "Decisions")
        #expect(diff.onlyInFirst.first?.lines == ["Keep web app"])
        #expect(diff.onlyInSecond.isEmpty)
    }

    @Test func matchingIgnoresCasePunctuationAndWhitespace() {
        let first: [Section] = [("Decisions", ["Ship offline sync.", "Drop LEGACY import!"])]
        let second: [Section] = [("Decisions", ["ship offline sync", "  drop   legacy import"])]
        #expect(SummaryDiff.compare(first: first, second: second).isEmpty)
    }

    @Test func lineSharedAcrossSectionsIsNotADifference() {
        // A bullet that moved sections is still "in both" — matching is
        // whole-summary, so only genuinely absent lines are reported.
        let first: [Section] = [("A", ["Shared line", "Only in A"])]
        let second: [Section] = [("B", ["Shared line"]), ("C", ["Only in C"])]
        let diff = SummaryDiff.compare(first: first, second: second)
        #expect(diff.onlyInFirst.first?.lines == ["Only in A"])
        #expect(diff.onlyInSecond.first?.title == "C")
        #expect(diff.onlyInSecond.first?.lines == ["Only in C"])
    }

    @Test func sectionsWithNoUniqueLinesAreDropped() {
        let first: [Section] = [("Intro", ["Same"]), ("Decisions", ["Same", "Different"])]
        let second: [Section] = [("Intro", ["Same"]), ("Decisions", ["Same"])]
        let diff = SummaryDiff.compare(first: first, second: second)
        #expect(diff.onlyInFirst.map(\.title) == ["Decisions"])
    }
}
