//
//  ReliabilityEventStoreTests.swift
//  KurnTests
//
//  H9 PR 22. Real round-trips against the on-disk store (matching
//  `DiagnosticReportStoreTests`' own convention) rather than a mock
//  filesystem — `clear()` at the start and in `defer` keeps each test
//  isolated from whatever a previous run left behind.
//

import Foundation
import KurnCore
import Testing
@testable import Kurn

@Suite(.serialized)
struct ReliabilityEventStoreTests {

    private func makeEvent(operation: String = "test_operation", outcome: ReliabilityEvent.Outcome = .succeeded) -> ReliabilityEvent {
        ReliabilityEvent(operationID: OperationID(), operation: operation, outcome: outcome)
    }

    @Test func recordAndReadRoundTrip() {
        ReliabilityEventStore.clear()
        defer { ReliabilityEventStore.clear() }

        ReliabilityEventStore.record(makeEvent(operation: "transcription", outcome: .started))
        ReliabilityEventStore.record(makeEvent(operation: "transcription", outcome: .succeeded))

        let events = ReliabilityEventStore.recentEvents()
        #expect(events.count == 2)
        // Newest first.
        #expect(events[0].outcome == .succeeded)
        #expect(events[1].outcome == .started)
        #expect(events.allSatisfy { $0.operation == "transcription" })
    }

    @Test func clearEmptiesTheStore() {
        ReliabilityEventStore.clear()
        ReliabilityEventStore.record(makeEvent())
        #expect(!ReliabilityEventStore.recentEvents().isEmpty)

        ReliabilityEventStore.clear()

        #expect(ReliabilityEventStore.recentEvents().isEmpty)
    }

    @Test func recentEventsRespectsLimit() {
        ReliabilityEventStore.clear()
        defer { ReliabilityEventStore.clear() }

        for _ in 0..<10 {
            ReliabilityEventStore.record(makeEvent())
        }

        #expect(ReliabilityEventStore.recentEvents(limit: 3).count == 3)
    }

    @Test func bufferIsBoundedAfterExceedingTheMargin() {
        ReliabilityEventStore.clear()
        defer { ReliabilityEventStore.clear() }

        let total = ReliabilityEventStore.maxEvents + ReliabilityEventStore.pruneMargin + 1
        for i in 0..<total {
            ReliabilityEventStore.record(makeEvent(operation: "op-\(i)"))
        }

        let events = ReliabilityEventStore.recentEvents(limit: total)
        #expect(events.count <= ReliabilityEventStore.maxEvents + ReliabilityEventStore.pruneMargin)
        // The most recent event survives pruning.
        #expect(events.first?.operation == "op-\(total - 1)")
    }
}
