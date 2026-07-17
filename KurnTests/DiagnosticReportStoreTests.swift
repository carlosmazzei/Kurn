//
//  DiagnosticReportStoreTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct DiagnosticReportStoreTests {
    @Test func urlsToDeleteKeepsOnlyMostRecent() {
        let base = Date()
        let entries: [(url: URL, date: Date)] = (0..<5).map { index in
            (url: URL(fileURLWithPath: "/tmp/report-\(index).txt"), date: base.addingTimeInterval(TimeInterval(index)))
        }
        let toDelete = DiagnosticReportStore.urlsToDelete(from: entries, keeping: 3)
        // Keeps the 3 most recent (indices 2, 3, 4); deletes the 2 oldest.
        #expect(toDelete.count == 2)
        #expect(toDelete.contains(URL(fileURLWithPath: "/tmp/report-0.txt")))
        #expect(toDelete.contains(URL(fileURLWithPath: "/tmp/report-1.txt")))
    }

    @Test func urlsToDeleteIsEmptyWhenUnderLimit() {
        let entries: [(url: URL, date: Date)] = [
            (url: URL(fileURLWithPath: "/tmp/a.txt"), date: Date())
        ]
        #expect(DiagnosticReportStore.urlsToDelete(from: entries, keeping: 20).isEmpty)
    }

    @Test func saveListAndDeleteRoundTrip() throws {
        let receivedAt = Date()
        let url = try DiagnosticReportStore.save("hello world", kind: .crash, receivedAt: receivedAt)
        defer { try? FileManager.default.removeItem(at: url) }

        let entries = DiagnosticReportStore.list()
        let saved = try #require(entries.first { $0.url == url })
        #expect(saved.kind == .crash)
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello world")

        DiagnosticReportStore.delete(saved)
        #expect(!DiagnosticReportStore.list().contains { $0.url == url })
    }
}
