//
//  UsageInsightsView.swift
//  Kurn
//
//  Read-only view of the local-only usage counters in AppSettings.usageStats:
//  recordings completed, transcription engine usage, and summary template
//  usage. Nothing here is ever transmitted off-device; "Clear my data" resets
//  the counters.
//

import SwiftUI

struct UsageInsightsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var showingClearConfirm = false

    private var stats: UsageStats { settings.usageStatsSnapshot }

    var body: some View {
        NavigationStack {
            List {
                overviewSection
                engineSection
                templateSection
                clearSection
            }
            .navigationTitle(NSLocalizedString("usage_insights.title", comment: "Usage Insights"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
            .kurnDialog(
                isPresented: $showingClearConfirm,
                iconSystemName: "trash.fill",
                iconTint: Theme.accent,
                title: NSLocalizedString("usage_insights.clear_confirm", comment: "Confirm clear usage data"),
                message: NSLocalizedString("usage_insights.clear_message", comment: "Clear usage data message"),
                primaryTitle: NSLocalizedString("usage_insights.clear", comment: "Clear My Data"),
                primaryRole: .destructive,
                primaryAction: { settings.resetUsageStats() },
                secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
            )
        }
    }

    private var overviewSection: some View {
        Section(NSLocalizedString("usage_insights.overview", comment: "Overview")) {
            LabeledContent(
                NSLocalizedString("usage_insights.recordings_completed", comment: "Recordings completed"),
                value: "\(stats.recordingsCompleted)"
            )
            LabeledContent(
                NSLocalizedString("usage_insights.most_used_engine", comment: "Most-used transcription engine"),
                value: stats.mostUsedTranscriptionEngine?.displayName ?? "—"
            )
        }
    }

    private var engineSection: some View {
        Section(NSLocalizedString("usage_insights.engine_usage", comment: "Transcription engine usage")) {
            if stats.transcriptionEngineUsage.isEmpty {
                Text(NSLocalizedString("usage_insights.empty", comment: "No data yet"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(sortedUsage(stats.transcriptionEngineUsage), id: \.key) { key, count in
                    HStack {
                        Text(TranscriptionEngine(rawValue: key)?.displayName ?? key)
                        Spacer()
                        Text("\(count)").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private var templateSection: some View {
        Section(NSLocalizedString("usage_insights.summary_templates", comment: "Summary template usage")) {
            if stats.summaryTemplateUsage.isEmpty {
                Text(NSLocalizedString("usage_insights.empty", comment: "No data yet"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(sortedUsage(stats.summaryTemplateUsage), id: \.key) { key, count in
                    HStack {
                        Text(settings.template(for: key)?.displayName ?? key)
                        Spacer()
                        Text("\(count)").foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private var clearSection: some View {
        Section {
            Button(role: .destructive) { showingClearConfirm = true } label: {
                Text(NSLocalizedString("usage_insights.clear", comment: "Clear My Data"))
            }
        } footer: {
            Text(NSLocalizedString("usage_insights.footer", comment: "Explains local-only usage data"))
        }
    }

    private func sortedUsage(_ usage: [String: Int]) -> [(key: String, value: Int)] {
        usage.sorted { $0.value > $1.value }
    }
}
