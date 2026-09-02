//
//  ReliabilityEventsListView.swift
//  Kurn
//
//  H9 PR 22, item 6's "redaction preview": every field on `ReliabilityEvent`
//  is content-free by construction (see `ReliabilityEvent.swift`'s own
//  header), so simply showing exactly what would be exported — nothing more
//  — already delivers the transparency a redaction preview is for, with no
//  separate redaction pass needed. Mirrors `DiagnosticReportsListView`'s
//  list/share/delete shape for MetricKit reports.
//

import SwiftUI
import KurnCore

struct ReliabilityEventsListView: View {
    @State private var events: [ReliabilityEvent] = []
    @State private var shareItem: ShareItem?
    @State private var shareError: AppError?

    var body: some View {
        List {
            if events.isEmpty {
                Text(NSLocalizedString("settings.reliability_events.empty", comment: "No reliability events"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                // `operationID` deliberately repeats across every event from
                // the same operation run (that's the point — it's what
                // correlates them), so it can't be the `ForEach` identity;
                // `events` is only ever replaced wholesale by `refresh()`,
                // never reordered in place, so a plain positional id is safe.
                ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.logLine)
                                .font(.system(.footnote, design: .monospaced))
                            Spacer()
                        }
                        Text(event.recordedAt.meetingDisplay)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle(NSLocalizedString("settings.reliability_events.view", comment: "View reliability events"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    share()
                } label: {
                    Label(NSLocalizedString("detail.share", comment: "Share"), systemImage: "square.and.arrow.up")
                }
                .disabled(events.isEmpty)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: item.urls)
        }
        .errorAlert($shareError)
    }

    private func refresh() {
        events = ReliabilityEventStore.recentEvents()
    }

    private func share() {
        let text = events.map(\.logLine).joined(separator: "\n")
        do {
            let url = try MeetingExport.temporaryFile(markdown: text, suggestedName: "kurn-reliability-events")
            shareItem = ShareItem(urls: [url])
        } catch {
            shareError = .logExportFailed(error.localizedDescription)
        }
    }
}
