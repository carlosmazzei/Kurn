//
//  DiagnosticPayloadIntakeTests.swift
//  KurnTests
//
//  What happens to a MetricKit delivery: nothing without consent, one report
//  per crash or hang a payload carries, and a failed save that neither stops
//  the others nor escapes as an error.
//

import Foundation
import Testing
@testable import Kurn

struct DiagnosticPayloadIntakeTests {

    private let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let json = Data(#"{"crashDiagnostics":[]}"#.utf8)

    private func payload(crash: Bool, hang: Bool) -> DiagnosticPayloadIntake.Payload {
        DiagnosticPayloadIntake.Payload(receivedAt: receivedAt, hasCrash: crash, hasHang: hang, json: json)
    }

    private struct SaveFailed: Error {}

    @Test func withoutConsentNothingIsKept() {
        let reports = DiagnosticPayloadIntake.reports(
            for: [payload(crash: true, hang: true)],
            consented: false,
            appVersion: "1.0",
            osVersion: "26.0"
        )
        #expect(reports.isEmpty)
    }

    @Test func payloadsWithoutCrashOrHangAreSkipped() {
        let reports = DiagnosticPayloadIntake.reports(
            for: [payload(crash: false, hang: false)],
            consented: true,
            appVersion: "1.0",
            osVersion: "26.0"
        )
        #expect(reports.isEmpty)
    }

    @Test func eachKindAPayloadCarriesBecomesAReport() {
        let reports = DiagnosticPayloadIntake.reports(
            for: [payload(crash: true, hang: true), payload(crash: false, hang: true)],
            consented: true,
            appVersion: "1.0",
            osVersion: "26.0"
        )
        #expect(reports.map(\.kind) == [.crash, .hang, .hang])
        #expect(reports.allSatisfy { $0.receivedAt == receivedAt })
        let expected = DiagnosticReportFormatter.format(
            kind: .crash, receivedAt: receivedAt, appVersion: "1.0", osVersion: "26.0", jsonRepresentation: json
        )
        #expect(reports.first?.text == expected)
    }

    @Test func persistSavesEveryReportAndSurvivesAFailure() {
        let reports = DiagnosticPayloadIntake.reports(
            for: [payload(crash: true, hang: true)],
            consented: true,
            appVersion: "1.0",
            osVersion: "26.0"
        )
        var attempted: [DiagnosticReportFormatter.Kind] = []
        let saved = DiagnosticPayloadIntake.persist(reports) { _, kind, _ in
            attempted.append(kind)
            if kind == .crash { throw SaveFailed() }
        }
        #expect(attempted == [.crash, .hang])
        #expect(saved == 1)
    }

    @Test func persistWritesToTheReportStoreByDefault() throws {
        let report = DiagnosticPayloadIntake.Report(kind: .hang, receivedAt: Date(), text: "intake-default-\(UUID())")
        #expect(DiagnosticPayloadIntake.persist([report]) == 1)
        let entry = try #require(DiagnosticReportStore.list().first {
            (try? String(contentsOf: $0.url, encoding: .utf8)) == report.text
        })
        DiagnosticReportStore.delete(entry)
    }

    @Test func consentIsReadFromDefaults() throws {
        let suite = "DiagnosticPayloadIntakeTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!DiagnosticPayloadIntake.isConsented(in: defaults))
        defaults.set(true, forKey: AppSettingsKeys.diagnosticReportsConsented)
        #expect(DiagnosticPayloadIntake.isConsented(in: defaults))
    }

    @Test func appVersionFallsBackWhenTheBundleHasNone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID()).bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try #require(Bundle(url: directory))
        #expect(DiagnosticPayloadIntake.appVersion(in: bundle) == "unknown")
        #expect(!DiagnosticPayloadIntake.appVersion().isEmpty)
    }
}
