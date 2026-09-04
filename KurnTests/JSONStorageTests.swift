//
//  JSONStorageTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct JSONStorageTests {

    private struct Point: Codable, Equatable {
        var x: Double
        var y: Double
    }

    // MARK: - Lenient encode/decode (existing contract, unchanged)

    @Test func lenientDecodeOfGarbageDataFallsBackToEmptyArray() {
        let result = JSONStorage.decode([Point].self, from: Data("not json".utf8))
        #expect(result.isEmpty)
    }

    @Test func lenientDecodeOfGarbageDataFallsBackToNilForASingleValue() {
        let result = JSONStorage.decode(Point.self, from: Data("not json".utf8))
        #expect(result == nil)
    }

    // MARK: - Authoritative encode/decode

    @Test func roundTripsThroughEncodeAndDecodeAuthoritative() {
        let value = [Point(x: 1, y: 2), Point(x: 3, y: 4)]
        guard let data = JSONStorage.encodeAuthoritative(value) else {
            Issue.record("expected a successful encode")
            return
        }

        let outcome = JSONStorage.decodeAuthoritative([Point].self, from: data)

        guard case .value(let decoded) = outcome else {
            Issue.record("expected .value, got \(outcome)")
            return
        }
        #expect(decoded == value)
    }

    @Test func decodeAuthoritativeOfZeroBytesIsEmptyNotCorrupted() {
        let outcome = JSONStorage.decodeAuthoritative([Point].self, from: Data())
        guard case .empty = outcome else {
            Issue.record("expected .empty, got \(outcome)")
            return
        }
    }

    @Test func decodeAuthoritativeOfGarbageBytesIsCorrupted() {
        let garbage = Data("definitely not an envelope".utf8)
        let outcome = JSONStorage.decodeAuthoritative([Point].self, from: garbage)

        guard case .corrupted(let originalData) = outcome else {
            Issue.record("expected .corrupted, got \(outcome)")
            return
        }
        // The original bytes are preserved for recovery, not discarded.
        #expect(originalData == garbage)
    }

    @Test func decodeAuthoritativeDetectsATamperedChecksum() {
        let value = [Point(x: 1, y: 2)]
        guard let data = JSONStorage.encodeAuthoritative(value) else {
            Issue.record("expected a successful encode")
            return
        }
        // Flip one byte near the end, inside the payload rather than the
        // outer envelope's own structural bytes, so the result is still
        // syntactically valid JSON — the case a checksum catches that a
        // plain decode-and-see-if-it-parses check would not.
        var bytes = [UInt8](data)
        bytes[bytes.count - 5] ^= 0xFF
        let tampered = Data(bytes)

        let outcome = JSONStorage.decodeAuthoritative([Point].self, from: tampered)
        #expect(outcome.isCorrupted)
    }

    @Test func decodeAuthoritativeAcceptsPreEnvelopeLegacyBytes() {
        // Every row written before this format existed has bare JSON with no
        // envelope or checksum. A successful decode of that shape is real
        // content, not corruption, or every pre-existing row would appear
        // corrupted the moment this shipped.
        let value = [Point(x: 5, y: 6)]
        let legacyData = JSONStorage.encode(value)

        let outcome = JSONStorage.decodeAuthoritative([Point].self, from: legacyData)

        guard case .value(let decoded) = outcome else {
            Issue.record("expected .value for legacy-format bytes, got \(outcome)")
            return
        }
        #expect(decoded == value)
        #expect(!outcome.isCorrupted)
    }

    @Test func decodeAuthoritativeRefusesAFutureEnvelopeVersionWithoutCallingItCorrupted() {
        // An envelope written by a newer build is intact content this build
        // cannot interpret. Reading its payload anyway would trust a format
        // whose rules are unknown here; calling it corrupted would invite a
        // "repair" that discards the newer build's data. Both are wrong.
        let payload = JSONStorage.encode([Point(x: 1, y: 2)]).base64EncodedString()
        let future = Data("{\"version\":999,\"payloadChecksum\":0,\"payload\":\"\(payload)\"}".utf8)

        let outcome = JSONStorage.decodeAuthoritative([Point].self, from: future)

        guard case .unsupportedVersion(let version, let originalData) = outcome else {
            Issue.record("expected .unsupportedVersion, got \(outcome)")
            return
        }
        #expect(version == 999)
        #expect(originalData == future)
        #expect(outcome.decodedValue == nil)
        #expect(!outcome.isCorrupted)
        #expect(outcome.isUnreadable)
    }

    @Test func encodeAuthoritativeFailsRatherThanProducingData() {
        // JSONEncoder has no JSON representation for NaN/infinite floating
        // point values and throws for them by default — a real, if rare,
        // failure mode for a pipeline-computed timestamp or confidence
        // score. The old `JSONStorage.encode` swallowed this into `Data()`,
        // indistinguishable from genuinely empty content.
        let value = [Point(x: .nan, y: 0)]
        #expect(JSONStorage.encodeAuthoritative(value) == nil)
    }

    @Test func encodeAuthoritativeSucceedsForOrdinaryFiniteValues() {
        let value = [Point(x: 0, y: -1.5)]
        #expect(JSONStorage.encodeAuthoritative(value) != nil)
    }

    // MARK: - JSONDecodeOutcome

    @Test func decodeOutcomeValueAccessorReturnsNilForEmptyAndCorrupted() {
        let empty: JSONDecodeOutcome<Point> = .empty
        let corrupted: JSONDecodeOutcome<Point> = .corrupted(originalData: Data())
        let decoded: JSONDecodeOutcome<Point> = .value(Point(x: 1, y: 1))

        #expect(empty.decodedValue == nil)
        #expect(corrupted.decodedValue == nil)
        #expect(decoded.decodedValue == Point(x: 1, y: 1))
    }

    @Test func decodeOutcomeIsCorruptedOnlyForTheCorruptedCase() {
        let empty: JSONDecodeOutcome<Point> = .empty
        let corrupted: JSONDecodeOutcome<Point> = .corrupted(originalData: Data())
        let decoded: JSONDecodeOutcome<Point> = .value(Point(x: 1, y: 1))

        #expect(empty.isCorrupted == false)
        #expect(corrupted.isCorrupted == true)
        #expect(decoded.isCorrupted == false)
    }
}
