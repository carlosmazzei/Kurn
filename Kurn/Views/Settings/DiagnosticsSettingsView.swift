//
//  DiagnosticsSettingsView.swift
//  Kurn
//
//  Logging threshold, log export, and the opt-in on-device MetricKit reports.
//  Nothing here leaves the device unless the user shares an exported file.
//

import SwiftUI
import KurnCore

struct DiagnosticsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    /// Share sheet payload for an exported log file, set by `exportLogs()`.
    @State private var shareItem: ShareItem?
    /// Surfaced if reading/writing the log export fails.
    @State private var logExportError: AppError?
    /// Consent dialog for opting in to on-device MetricKit diagnostic reports.
    @State private var showingDiagnosticReportsConsent = false

    var body: some View {
        Form {
            loggingSection
            diagnosticReportsSection
            reliabilityEventsSection
        }
        .navigationTitle(NSLocalizedString("settings.diagnostics", comment: "Diagnostics"))
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.urls)
        }
        .errorAlert($logExportError)
        .kurnDialog(
            isPresented: $showingDiagnosticReportsConsent,
            iconSystemName: "exclamationmark.triangle.fill",
            iconTint: Theme.info,
            title: NSLocalizedString("settings.diagnostic_reports.consent_title", comment: "Enable diagnostic reports"),
            message: NSLocalizedString("settings.diagnostic_reports.consent_message", comment: "Explains on-device diagnostic reports"),
            primaryTitle: NSLocalizedString("settings.diagnostic_reports.enable", comment: "Enable"),
            primaryAction: { settings.diagnosticReportsConsented = true },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }

    // MARK: - Sections

    // One section per topic (logging / crash reports / reliability events) so
    // each control's explanation sits under it, not in a shared footer four
    // rows below the toggle it describes.
    private var loggingSection: some View {
        Section {
            Picker(
                selection: Binding(
                    get: { settings.logLevel },
                    set: { settings.logLevel = $0 }
                )
            ) {
                ForEach(LogLevel.allCases) { Text($0.displayName).tag($0) }
            } label: {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.log_level", comment: "Logging level"),
                    detail: NSLocalizedString("settings.log_level_footer", comment: "Explains logging levels")
                )
            }
            Button {
                exportLogs()
            } label: {
                Label {
                    SettingsRowLabel(
                        title: NSLocalizedString("settings.export_logs", comment: "Export logs"),
                        detail: NSLocalizedString("settings.export_logs_footer", comment: "Explains log export")
                    )
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            NavigationLink {
                LogEntriesListView()
            } label: {
                Label(NSLocalizedString("settings.view_logs", comment: "View recent logs"), systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    private var diagnosticReportsSection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { settings.diagnosticReportsConsented },
                    set: { enabled in
                        if enabled {
                            showingDiagnosticReportsConsent = true
                        } else {
                            settings.diagnosticReportsConsented = false
                        }
                    }
                )
            ) {
                SettingsRowLabel(
                    title: NSLocalizedString("settings.diagnostic_reports", comment: "Diagnostic reports"),
                    detail: NSLocalizedString("settings.diagnostic_reports_footer", comment: "Explains diagnostic reports")
                )
            }
            NavigationLink {
                DiagnosticReportsListView()
            } label: {
                Label(
                    NSLocalizedString("settings.diagnostic_reports.view", comment: "View diagnostic reports"),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private var reliabilityEventsSection: some View {
        Section {
            NavigationLink {
                ReliabilityEventsListView()
            } label: {
                Label(
                    NSLocalizedString("settings.reliability_events.view", comment: "View reliability events"),
                    systemImage: "checklist"
                )
            }
        } header: {
            Text(NSLocalizedString("settings.reliability_events", comment: "Reliability events"))
        } footer: {
            Text(NSLocalizedString("settings.reliability_events_footer", comment: "Explains reliability events"))
        }
    }

    private func exportLogs() {
        do {
            let url = try LogExport.temporaryFile()
            shareItem = ShareItem(urls: [url])
        } catch {
            logExportError = .logExportFailed(error.localizedDescription)
        }
    }
}
