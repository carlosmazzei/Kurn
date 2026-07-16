//
//  DiagnosticReportsListView.swift
//  Kurn
//
//  Lists on-device MetricKit diagnostic reports (crash/hang) captured by
//  DiagnosticsSubscriber. Sharing a report writes a *temporary copy* rather
//  than sharing the persisted store file's URL directly, because
//  ActivityView's completion handler deletes the parent directory of every
//  shared file — sharing the original would delete the user's only copy the
//  moment the share sheet closes.
//

import SwiftUI

struct DiagnosticReportsListView: View {
    @State private var entries: [DiagnosticReportEntry] = []
    @State private var shareItem: ShareItem?
    @State private var shareError: AppError?

    var body: some View {
        List {
            if entries.isEmpty {
                Text(NSLocalizedString("settings.diagnostic_reports.empty", comment: "No diagnostic reports"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(entries) { entry in
                    Button {
                        share(entry)
                    } label: {
                        HStack {
                            Image(systemName: entry.kind == .crash ? "exclamationmark.triangle.fill" : "hourglass")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading) {
                                Text(entry.kind == .crash
                                    ? NSLocalizedString("settings.diagnostic_reports.crash", comment: "Crash")
                                    : NSLocalizedString("settings.diagnostic_reports.hang", comment: "Hang"))
                                Text(entry.receivedAt.meetingDisplay)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteEntries)
            }
        }
        .navigationTitle(NSLocalizedString("settings.diagnostic_reports.view", comment: "View diagnostic reports"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.urls)
        }
        .errorAlert($shareError)
    }

    private func refresh() {
        entries = DiagnosticReportStore.list()
    }

    private func share(_ entry: DiagnosticReportEntry) {
        do {
            let text = try String(contentsOf: entry.url, encoding: .utf8)
            let url = try MeetingExport.temporaryFile(
                markdown: text,
                suggestedName: "kurn-diagnostic-\(entry.kind.rawValue)-\(entry.id)"
            )
            shareItem = ShareItem(urls: [url])
        } catch {
            shareError = .persistenceFailed(error.localizedDescription)
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            DiagnosticReportStore.delete(entries[index])
        }
        refresh()
    }
}
