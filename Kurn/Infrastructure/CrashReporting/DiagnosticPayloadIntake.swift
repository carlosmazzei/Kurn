//
//  DiagnosticPayloadIntake.swift
//  Kurn
//
//  What `DiagnosticsSubscriber` does with a MetricKit delivery, minus
//  MetricKit: discard everything without consent, keep only payloads that
//  carry a crash or a hang, write one formatted report per kind, and log —
//  never throw — a report that fails to save. `MXDiagnosticPayload` cannot be
//  constructed in a test, so the subscriber reads each payload into a
//  `Payload` and hands the decision to this type.
//

import Foundation

enum DiagnosticPayloadIntake {
    /// The parts of an `MXDiagnosticPayload` a report is built from.
    struct Payload: Equatable {
        var receivedAt: Date
        var hasCrash: Bool
        var hasHang: Bool
        var json: Data
    }

    struct Report: Equatable {
        var kind: DiagnosticReportFormatter.Kind
        var receivedAt: Date
        var text: String
    }

    typealias Save = (String, DiagnosticReportFormatter.Kind, Date) throws -> Void

    /// Consent is read at delivery time, straight from `UserDefaults`, so a
    /// delivery that races `AppSettings`' construction still honours it.
    static func isConsented(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppSettingsKeys.diagnosticReportsConsented)
    }

    static func appVersion(in bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// One report per kind a payload carries; a payload with both a crash and
    /// a hang yields two. Without consent, nothing.
    static func reports(
        for payloads: [Payload],
        consented: Bool,
        appVersion: String,
        osVersion: String
    ) -> [Report] {
        guard consented else { return [] }
        return payloads.flatMap { payload -> [Report] in
            let kinds: [DiagnosticReportFormatter.Kind] =
                (payload.hasCrash ? [.crash] : []) + (payload.hasHang ? [.hang] : [])
            return kinds.map { kind in
                Report(
                    kind: kind,
                    receivedAt: payload.receivedAt,
                    text: DiagnosticReportFormatter.format(
                        kind: kind,
                        receivedAt: payload.receivedAt,
                        appVersion: appVersion,
                        osVersion: osVersion,
                        jsonRepresentation: payload.json
                    )
                )
            }
        }
    }

    /// Saves every report, continuing past a failure. Returns how many saved.
    @discardableResult
    static func persist(
        _ reports: [Report],
        save: Save = { text, kind, receivedAt in
            _ = try DiagnosticReportStore.save(text, kind: kind, receivedAt: receivedAt)
        }
    ) -> Int {
        var saved = 0
        for report in reports {
            do {
                try save(report.text, report.kind, report.receivedAt)
                saved += 1
            } catch {
                AppLog.persistence.atError.error(
                    "diagnostics: failed to save \(report.kind.rawValue, privacy: .public) report code=\(error.publicLogCode, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
                )
            }
        }
        return saved
    }
}
