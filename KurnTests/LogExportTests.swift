//
//  LogExportTests.swift
//  KurnTests
//
//  Tests LogExport.formatText against synthetic snapshots — deliberately does
//  not touch a live OSLogStore (unreliable/slow in a test target); the live
//  OSLogStore.local() path (fetchRecentEntries) is exercised manually/in CI's
//  real app environment instead.
//

import Foundation
import os
import Testing
@testable import Kurn

struct LogExportTests {
    @Test func formatTextIncludesHeaderAndEntryCount() {
        let entries = [
            LogEntrySnapshot(date: Date(timeIntervalSince1970: 1), category: "Recorder", level: .notice, message: "started"),
            LogEntrySnapshot(date: Date(timeIntervalSince1970: 2), category: "UI", level: .error, message: "failed")
        ]
        let text = LogExport.formatText(entries: entries, generatedAt: Date(timeIntervalSince1970: 3))
        #expect(text.contains("Entries: 2"))
        #expect(text.contains("Recorder"))
        #expect(text.contains("started"))
        #expect(text.contains("UI"))
        #expect(text.contains("failed"))
    }

    @Test func formatTextPreservesEntryOrder() throws {
        let entries = [
            LogEntrySnapshot(date: Date(timeIntervalSince1970: 1), category: "A", level: .info, message: "first"),
            LogEntrySnapshot(date: Date(timeIntervalSince1970: 2), category: "B", level: .info, message: "second")
        ]
        let text = LogExport.formatText(entries: entries, generatedAt: Date())
        let firstRange = try #require(text.range(of: "first"))
        let secondRange = try #require(text.range(of: "second"))
        #expect(firstRange.lowerBound < secondRange.lowerBound)
    }

    @Test func formatTextHandlesEmptyEntries() {
        let text = LogExport.formatText(entries: [], generatedAt: Date())
        #expect(text.contains("Entries: 0"))
    }
}
