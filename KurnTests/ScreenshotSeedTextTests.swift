//
//  ScreenshotSeedTextTests.swift
//  KurnTests
//
//  `ScreenshotSeedData` zips each table's lines with fixed speaker timelines,
//  so a translation with a missing line would silently drop a transcript row
//  from one language's App Store screenshots. These pin every table to the
//  English shape and the language a `snapshot` launch selects.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ScreenshotSeedTextTests {
    @Test func everyLanguageHasTheEnglishShape() {
        let english = ScreenshotSeedText.english
        for (code, table) in ScreenshotSeedText.byLanguageCode {
            #expect(table.roadmapTags.count == english.roadmapTags.count, "\(code)")
            #expect(table.roadmapLines.count == english.roadmapLines.count, "\(code)")
            #expect(table.roadmapFollowUp.count == english.roadmapFollowUp.count, "\(code)")
            #expect(table.roadmapSections.map(\.items.count) == english.roadmapSections.map(\.items.count), "\(code)")
            #expect(table.designLines.count == english.designLines.count, "\(code)")
            #expect(table.designSections.map(\.items.count) == english.designSections.map(\.items.count), "\(code)")
            #expect(table.onboardingTags.count == english.onboardingTags.count, "\(code)")
            #expect(table.onboardingLines.count == english.onboardingLines.count, "\(code)")
            #expect(table.onboardingCheckIn.count == english.onboardingCheckIn.count, "\(code)")
            #expect(table.onboardingSections.map(\.items.count) == english.onboardingSections.map(\.items.count), "\(code)")
            #expect(table.interviewLines.count == english.interviewLines.count, "\(code)")
        }
    }

    @Test func theSnapshotLanguageSelectsItsTable() {
        #expect(ScreenshotSeedText.current(preferredLanguages: ["pt-BR"]).language == .portuguese)
        #expect(ScreenshotSeedText.current(preferredLanguages: ["zh-Hans-CN"]).language == .chinese)
        #expect(ScreenshotSeedText.current(preferredLanguages: ["it"]).language == .italian)
        #expect(ScreenshotSeedText.current(preferredLanguages: ["ja-JP", "de-DE"]).language == .german)
        #expect(ScreenshotSeedText.current(preferredLanguages: ["ja"]).language == .english)
        #expect(ScreenshotSeedText.current(preferredLanguages: []).language == .english)
    }
}
