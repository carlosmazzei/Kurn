//
//  ModelStoreSalvageTests.swift
//  KurnSwiftDataTests
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

// Nested inside `SwiftDataConcurrencySensitiveTests` (Support/) rather than
// a bare `@Suite(.serialized)` at the top level: each test here opens its
// own real, on-disk ModelContainer, including against corrupt/unreadable
// store paths — exactly the case SwiftData's own concurrent-container
// handling is least tested against — and it must never run concurrently
// with `ModelStoreBootCoordinatorTests` either. See that parent type's
// header comment.
extension SwiftDataConcurrencySensitiveTests {
@MainActor
struct SalvageTests {

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
            let configuration = ModelConfiguration(schema: schema, url: storeURL)

            // Scoped to match production, where salvage only ever runs from
            // the recovery screen — which exists because the live open
            // already failed, so no live container is open at this point.
            //
            // Scoping it does not, on its own, make this test pass: it was
            // tried for that and did not help. The crash this test kept
            // hitting was `ModelStoreSalvage` returning fetched `Meeting`s
            // out of the scope of the container it fetched them from, and
            // the fix is there, not here.
            do {
                let container = try ModelContainer(
                    for: schema, migrationPlan: KurnModelGraph.migrationPlan, configurations: [configuration]
                )
                let meeting = Meeting(title: "Salvage Candidate", language: .english)
                container.mainContext.insert(meeting)
                try container.mainContext.save()
            }

            let (result, markdown) = ModelStoreSalvage.attempt(appSupportDirectory: directory)

            #expect(result == .recovered(meetingCount: 1))
            let unwrappedMarkdown = try #require(markdown)
            #expect(unwrappedMarkdown.contains("Salvage Candidate"))
            // Salvage must never touch the live store it copied from —
            // reopen fresh (rather than reusing the original instance,
            // which is gone) and confirm the write is still there.
            let reopened = try ModelContainer(
                for: schema, migrationPlan: KurnModelGraph.migrationPlan, configurations: [configuration]
            )
            let stillLive = try reopened.mainContext.fetch(FetchDescriptor<Meeting>())
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
}
