//
//  LogEntriesListView.swift
//  Kurn
//
//  A live in-app viewer for the app's own recent log entries — distinct from
//  DiagnosticReportsListView, which only lists MetricKit crash/hang reports.
//  Reuses LogExport.fetchRecentEntries, the same OSLogStore query the working
//  "Export Logs" action already relies on.
//

import SwiftUI

struct LogEntriesListView: View {
    @State private var entries: [LogEntrySnapshot] = []
    @State private var fetchError: AppError?

    var body: some View {
        List {
            if entries.isEmpty {
                Text(NSLocalizedString("settings.view_logs.empty", comment: "No recent log entries"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.category)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            Text(entry.level)
                                .font(.caption)
                                .foregroundStyle(levelColor(entry.level))
                            Text(entry.date, style: .time)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text(entry.message)
                            .font(.footnote)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.view_logs", comment: "View recent logs"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(NSLocalizedString("common.refresh", comment: "Refresh"))
            }
        }
        .onAppear { refresh() }
        .errorAlert($fetchError)
    }

    private func refresh() {
        do {
            // Newest first, for a live-debugging view; `fetchRecentEntries`
            // returns oldest-first (matching the export file's order).
            entries = try LogExport.fetchRecentEntries().reversed()
        } catch {
            fetchError = .logExportFailed(error.localizedDescription)
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "error", "fault": return Theme.accent
        case "notice": return Theme.info
        default: return Theme.textSecondary
        }
    }
}
