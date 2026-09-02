//
//  ReliabilityEventTests.swift
//  KurnCoreTests
//
//  Pins the two things `ReliabilityEvent` promises: `OperationID` produces a
//  short, stable-shaped id, and `logLine` renders a single line containing
//  exactly the fields supplied — nothing more, nothing less — so a caller can
//  trust that logging an event never accidentally interpolates content it
//  wasn't given.
//

import Foundation
import Testing
@testable import KurnCore

struct ReliabilityEventTests {

    @Test func operationIDIsShortAndUnique() {
        let first = OperationID()
        let second = OperationID()
        #expect(first.value.count == 8)
        #expect(first != second)
    }

    @Test func operationIDWrapsAnExistingValue() {
        let id = OperationID("abcd1234")
        #expect(id.value == "abcd1234")
        #expect("\(id)" == "abcd1234")
    }

    @Test func logLineIncludesOperationAndOutcome() {
        let event = ReliabilityEvent(
            operationID: OperationID("abcd1234"),
            operation: "document_generation",
            outcome: .succeeded
        )
        #expect(event.logLine == "document_generation: succeeded run=abcd1234")
    }

    @Test func logLineIncludesOptionalFieldsWhenPresent() {
        let event = ReliabilityEvent(
            operationID: OperationID("abcd1234"),
            operation: "document_generation",
            stage: "validation",
            outcome: .failed,
            attempt: 2,
            elapsedSeconds: 1.5,
            code: "no_transcripts"
        )
        #expect(event.logLine == "document_generation: failed run=abcd1234 stage=validation attempt=2 code=no_transcripts elapsed=1.50s")
    }

    @Test func logLineOmitsAbsentOptionalFields() {
        let event = ReliabilityEvent(
            operationID: OperationID("abcd1234"),
            operation: "document_generation",
            outcome: .cancelled
        )
        #expect(!event.logLine.contains("stage="))
        #expect(!event.logLine.contains("attempt="))
        #expect(!event.logLine.contains("code="))
        #expect(!event.logLine.contains("elapsed="))
    }

    @Test func recordInvokesTheInstalledHandler() {
        // `ReliabilityLog.handler` is `@Sendable`, so the captured box must be
        // too — a plain local `var` mutated from inside it is rejected under
        // Swift 6 strict concurrency.
        let capture = CapturedEventBox()
        ReliabilityLog.handler = { capture.set($0) }
        defer { ReliabilityLog.handler = nil }

        ReliabilityLog.record(ReliabilityEvent(
            operationID: OperationID(), operation: "test_operation", outcome: .started
        ))

        #expect(capture.value?.operation == "test_operation")
        #expect(capture.value?.outcome == .started)
    }

    // H9 PR 22: `ReliabilityEventStore` persists events as JSON, so a
    // round-trip through `Codable` has to preserve every field exactly —
    // including `recordedAt`, added in this PR for that store.
    @Test func roundTripsThroughJSONCoding() throws {
        let original = ReliabilityEvent(
            operationID: OperationID("abcd1234"),
            operation: "document_generation",
            stage: "validation",
            outcome: .failed,
            attempt: 2,
            elapsedSeconds: 1.5,
            code: "no_transcripts",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ReliabilityEvent.self, from: data)

        #expect(decoded.operationID == original.operationID)
        #expect(decoded.operation == original.operation)
        #expect(decoded.stage == original.stage)
        #expect(decoded.outcome == original.outcome)
        #expect(decoded.attempt == original.attempt)
        #expect(decoded.elapsedSeconds == original.elapsedSeconds)
        #expect(decoded.code == original.code)
        #expect(decoded.recordedAt == original.recordedAt)
    }
}

private final class CapturedEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ReliabilityEvent?

    func set(_ event: ReliabilityEvent) {
        lock.lock(); defer { lock.unlock() }
        stored = event
    }

    var value: ReliabilityEvent? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
