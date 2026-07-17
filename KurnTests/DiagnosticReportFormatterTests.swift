//
//  DiagnosticReportFormatterTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct DiagnosticReportFormatterTests {
    /// Small fixture resembling the shape of Apple's documented
    /// MXDiagnosticPayload JSON (a top-level object with metadata + a
    /// diagnostics array) — the formatter only needs it to be valid JSON, not
    /// a faithful replica, since it just re-serializes whatever it's given.
    private static let fixtureJSON = Data("""
    {"callStacks": [{"threadAttributed": true}], "diagnosticMetaData": {"exceptionType": 1}}
    """.utf8)

    @Test func formatIncludesHeaderFields() {
        let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let text = DiagnosticReportFormatter.format(
            kind: .crash,
            receivedAt: receivedAt,
            appVersion: "1.2.3",
            osVersion: "iOS 18.0",
            jsonRepresentation: Self.fixtureJSON
        )
        #expect(text.contains("crash"))
        #expect(text.contains("1.2.3"))
        #expect(text.contains("iOS 18.0"))
    }

    @Test func formatIncludesPrettyPrintedJSONBody() {
        let text = DiagnosticReportFormatter.format(
            kind: .hang,
            receivedAt: Date(),
            appVersion: "1.0",
            osVersion: "iOS 18.0",
            jsonRepresentation: Self.fixtureJSON
        )
        #expect(text.contains("threadAttributed"))
        #expect(text.contains("exceptionType"))
    }

    @Test func formatFallsBackToRawTextForNonJSONInput() {
        let raw = Data("not json".utf8)
        let text = DiagnosticReportFormatter.format(
            kind: .crash, receivedAt: Date(), appVersion: "1.0", osVersion: "iOS 18.0", jsonRepresentation: raw
        )
        #expect(text.contains("not json"))
    }
}
