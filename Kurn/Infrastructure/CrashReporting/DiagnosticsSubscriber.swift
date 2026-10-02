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
//  Only reads MetricKit's payloads; what is kept and how it is saved is
//  `DiagnosticPayloadIntake`'s decision.
//

#if canImport(MetricKit)
import Foundation
import MetricKit

final class DiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsSubscriber()

    private override init() {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let consented = DiagnosticPayloadIntake.isConsented()
        guard consented else {
            AppLog.persistence.atNotice.notice(
                "diagnostics: discarding \(payloads.count, privacy: .public) payload(s), not consented"
            )
            return
        }
        let reports = DiagnosticPayloadIntake.reports(
            for: payloads.map { payload in
                DiagnosticPayloadIntake.Payload(
                    receivedAt: payload.timeStampEnd,
                    hasCrash: !(payload.crashDiagnostics?.isEmpty ?? true),
                    hasHang: !(payload.hangDiagnostics?.isEmpty ?? true),
                    json: payload.jsonRepresentation()
                )
            },
            consented: consented,
            appVersion: DiagnosticPayloadIntake.appVersion(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        DiagnosticPayloadIntake.persist(reports)
    }

    /// No-op: this app surfaces diagnostic (crash/hang) reports only, not the
    /// periodic performance-metric payloads (CPU/battery/disk aggregates).
    func didReceive(_ payloads: [MXMetricPayload]) {}
}
#endif
