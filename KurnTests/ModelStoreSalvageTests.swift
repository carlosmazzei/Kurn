//
//  ModelStoreSalvageTests.swift
//  KurnTests
//
//  Proves H2 PR 4's salvage attempt (docs/resilience-megaplan.md) recovers
//  data from a real store copy without ever touching the live files, and
//  degrades to `.unavailable`/`.failed` rather than crashing when there is
//  nothing to recover.
//

import Foundation
import SwiftData
import Testing
@testable import Kurn

// Serialized: each test opens its own real ModelContainer against a file on
// disk, and this suite specifically exercises corrupt/unreadable store
// paths — exactly the case SwiftData's own concurrent-container handling is
// least tested against. Running these one at a time removes this suite as a
// contributor to any cross-test SwiftData concurrency issue, regardless of
// whether it turns out to be the actual cause.
@Suite(.serialized)
@MainActor
struct ModelStoreSalvageTests {

    private func withTempAppSupport(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreSalvageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func returnsUnavailableWhenNoLiveStoreExists() throws {
        try withTempAppSupport { directory in
            let (result, markdown) = ModelStoreSalvage.attempt(appSupportDirectory: directory)
            #expect(result == .unavailable)
            #expect(markdown == nil)
        }
    }

    @Test func recoversMeetingsFromARealStoreWithoutTouchingTheLiveFiles() throws {
        try withTempAppSupport { directory in
            let storeURL = directory.appendingPathComponent(ModelStoreProtection.baseName)
            let schema = KurnModelGraph.schema
            let container = try ModelContainer(
                for: schema,
                migrationPlan: KurnModelGraph.migrationPlan,
                configurations: [ModelConfiguration(schema: schema, url: storeURL)]
            )
            let meeting = Meeting(title: "Salvage Candidate", language: .english)
            container.mainContext.insert(meeting)
            try container.mainContext.save()

            let (result, markdown) = ModelStoreSalvage.attempt(appSupportDirectory: directory)

            #expect(result == .recovered(meetingCount: 1))
            let unwrappedMarkdown = try #require(markdown)
            #expect(unwrappedMarkdown.contains("Salvage Candidate"))
            // Salvage must never touch the live store it copied from — the
            // original container, still open, can still read its own write.
            let stillLive = try container.mainContext.fetch(FetchDescriptor<Meeting>())
            #expect(stillLive.count == 1)
        }
    }

    @Test func failsWithoutCrashingOnAnUnreadableStoreFile() throws {
        try withTempAppSupport { directory in
            let storeURL = directory.appendingPathComponent(ModelStoreProtection.baseName)
            try Data("not a real store".utf8).write(to: storeURL)

            let (result, markdown) = ModelStoreSalvage.attempt(appSupportDirectory: directory)

            guard case .failed = result else {
                Issue.record("Expected .failed for an unreadable store, got \(result)")
                return
            }
            #expect(markdown == nil)
        }
    }
}
