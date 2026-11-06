//
//  ReliabilityEventStoreTests.swift
//  KurnTests
//
//  Real round-trips against a per-test directory, independent of the
//  production events other concurrently running suites record.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

struct ReliabilityEventStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReliabilityEventStoreTests-\(UUID().uuidString)", isDirectory: true)

    private func makeEvent(operation: String = "test_operation", outcome: ReliabilityEvent.Outcome = .succeeded) -> ReliabilityEvent {
        ReliabilityEvent(operationID: OperationID(), operation: operation, outcome: outcome)
    }

    @Test func recordAndReadRoundTrip() throws {
        defer { try? FileManager.default.removeItem(at: directory) }

        ReliabilityEventStore.record(makeEvent(operation: "transcription", outcome: .started), directory: directory)
        ReliabilityEventStore.record(makeEvent(operation: "transcription", outcome: .succeeded), directory: directory)

        let events = ReliabilityEventStore.recentEvents(directory: directory)
        try #require(events.count == 2)
        // Newest first.
        #expect(events[0].outcome == .succeeded)
        #expect(events[1].outcome == .started)
        #expect(events.allSatisfy { $0.operation == "transcription" })
    }

    @Test func clearEmptiesTheStore() {
        defer { try? FileManager.default.removeItem(at: directory) }
        ReliabilityEventStore.record(makeEvent(), directory: directory)
        #expect(!ReliabilityEventStore.recentEvents(directory: directory).isEmpty)

        ReliabilityEventStore.clear(directory: directory)

        #expect(ReliabilityEventStore.recentEvents(directory: directory).isEmpty)
    }

    @Test func recentEventsRespectsLimit() {
        defer { try? FileManager.default.removeItem(at: directory) }

        for _ in 0..<10 {
            ReliabilityEventStore.record(makeEvent(), directory: directory)
        }

        #expect(ReliabilityEventStore.recentEvents(limit: 3, directory: directory).count == 3)
    }

    @Test func bufferIsBoundedAfterExceedingTheMargin() {
        defer { try? FileManager.default.removeItem(at: directory) }

        let total = ReliabilityEventStore.maxEvents + ReliabilityEventStore.pruneMargin + 1
        for i in 0..<total {
            ReliabilityEventStore.record(makeEvent(operation: "op-\(i)"), directory: directory)
        }

        let events = ReliabilityEventStore.recentEvents(limit: total, directory: directory)
        #expect(events.count <= ReliabilityEventStore.maxEvents + ReliabilityEventStore.pruneMargin)
        // The most recent event survives pruning.
        #expect(events.first?.operation == "op-\(total - 1)")
    }

    @Test func aNewStoreHasNoEvents() {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(ReliabilityEventStore.recentEvents(directory: directory).isEmpty)
        ReliabilityEventStore.clear(directory: directory)
        #expect(ReliabilityEventStore.recentEvents(directory: directory).isEmpty)
    }

    @Test func directoriesRemainIsolatedDuringConcurrentWritesAndClear() async {
        let otherDirectory = directory.appendingPathExtension("other")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                let first = makeEvent(operation: "first")
                let second = makeEvent(operation: "second")
                group.addTask {
                    ReliabilityEventStore.record(first, directory: directory)
                }
                group.addTask {
                    ReliabilityEventStore.record(second, directory: otherDirectory)
                }
            }
        }
        let events = ReliabilityEventStore.recentEvents(directory: directory)
        #expect(events.count == 20)
        #expect(events.allSatisfy { $0.operation == "first" })
        ReliabilityEventStore.clear(directory: directory)
        let otherEvents = ReliabilityEventStore.recentEvents(directory: otherDirectory)
        #expect(otherEvents.count == 20)
        #expect(otherEvents.allSatisfy { $0.operation == "second" })
    }

    @Test func anUnusableDirectoryDoesNotThrowOrReturnEvents() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)
        ReliabilityEventStore.record(makeEvent(), directory: directory)
        #expect(ReliabilityEventStore.recentEvents(directory: directory).isEmpty)
        ReliabilityEventStore.clear(directory: directory)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
