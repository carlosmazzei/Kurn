//
//  DiagnosticsSubscriber.swift
//  Kurn
//
//  Subscribes to MetricKit diagnostic payloads (crashes + hangs) delivered by
//  iOS, usually in a batch on the next launch after the event. Registered
//  unconditionally in KurnApp.init() so subscription itself doesn't depend on
//  AppSettings' construction order — consent is instead checked at delivery
//  time in didReceive(_:), reading UserDefaults directly. When consent is off,
//  every payload is discarded without touching disk; nothing is ever
//  transmitted anywhere automatically regardless of consent — reports only
//  leave the device via an explicit "Share" action in DiagnosticReportsListView.
//

#if canImport(MetricKit)
import Foundation
import MetricKit

final class DiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsSubscriber()

    private override init() {}

    private var isConsented: Bool {
        UserDefaults.standard.bool(forKey: AppSettingsKeys.diagnosticReportsConsented)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard isConsented else {
            AppLog.persistence.atNotice.notice(
                "diagnostics: discarding \(payloads.count, privacy: .public) payload(s), not consented"
            )
            return
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        for payload in payloads {
            let receivedAt = payload.timeStampEnd
            let hasCrash = !(payload.crashDiagnostics?.isEmpty ?? true)
            let hasHang = !(payload.hangDiagnostics?.isEmpty ?? true)
            guard hasCrash || hasHang else { continue }
            let json = payload.jsonRepresentation()
            if hasCrash {
                save(kind: .crash, receivedAt: receivedAt, appVersion: appVersion, osVersion: osVersion, json: json)
            }
            if hasHang {
                save(kind: .hang, receivedAt: receivedAt, appVersion: appVersion, osVersion: osVersion, json: json)
            }
        }
    }

    /// No-op: this app surfaces diagnostic (crash/hang) reports only, not the
    /// periodic performance-metric payloads (CPU/battery/disk aggregates).
    func didReceive(_ payloads: [MXMetricPayload]) {}

    private func save(
        kind: DiagnosticReportFormatter.Kind,
        receivedAt: Date,
        appVersion: String,
        osVersion: String,
        json: Data
    ) {
        let text = DiagnosticReportFormatter.format(
            kind: kind, receivedAt: receivedAt, appVersion: appVersion, osVersion: osVersion, jsonRepresentation: json
        )
        do {
            try DiagnosticReportStore.save(text, kind: kind, receivedAt: receivedAt)
        } catch {
            AppLog.persistence.atError.error(
                "diagnostics: failed to save \(kind.rawValue, privacy: .public) report: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
#endif
