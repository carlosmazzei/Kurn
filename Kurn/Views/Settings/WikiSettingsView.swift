//
//  WikiSettingsView.swift
//  Kurn
//
//  The LLM-generated meeting wiki: one condensed article per meeting, used by
//  the library-wide "Ask" so it can synthesize, compare, and count across
//  meetings. Unlike the on-device semantic index, building it calls the summary
//  AI provider, so it needs an explicit opt-in AND a usable provider: the
//  toggle stays disabled (with an explanatory footer) until one is — a
//  configured API key for a cloud provider, or a runnable model for the
//  on-device provider.
//

import SwiftUI

struct WikiSettingsView: View {
    /// Bumped by the providers screen when a key is added/removed, so this
    /// screen re-reads whether the summary provider is usable.
    var keyRevision: Int = 0

    @Environment(AppSettings.self) private var settings
    @Environment(WikiCoordinator.self) private var wiki

    /// Count of stored articles, refreshed on appear and after a bulk run/clear.
    @State private var wikiArticleCount = 0

    /// The reason the toggle is disabled, when it is. Names the specific
    /// on-device unavailability reason rather than always suggesting an API
    /// key, which would be the wrong instruction when the selected provider
    /// is on-device.
    private var unavailableFooter: String {
        if settings.aiProvider.kind == .appleOnDevice, let reason = OnDeviceModelAvailability.unavailableReason {
            return reason
        }
        return NSLocalizedString("settings.wiki_needs_key", comment: "Meeting wiki needs an API key")
    }

    var body: some View {
        let hasKey = settings.aiProvider.isUsable
        // `wiki.bulkOperation` is read straight from the coordinator (an
        // `@Observable`), so progress renders live instead of a plain spinner
        // this view has to poll for.
        let isBusy = wiki.bulkOperation != nil
        Form {
            Section {
                Toggle(
                    NSLocalizedString("settings.wiki", comment: "Meeting wiki toggle"),
                    isOn: Binding(
                        get: { settings.wikiEnabled && hasKey },
                        set: { settings.wikiEnabled = $0 }
                    )
                )
                .disabled(!hasKey)
                LabeledContent(
                    NSLocalizedString("settings.wiki_articles", comment: "Wiki article count"),
                    value: "\(wikiArticleCount)"
                )

                if let progress = wiki.bulkOperation {
                    bulkProgressRow(progress)
                }

                // Only fills in what's missing — meetings whose article is
                // already up to date are skipped, so opting in after months
                // of meetings doesn't re-pay for ones that already have one.
                Button {
                    Task {
                        await wiki.generateMissing()
                        wikiArticleCount = wiki.articleCount()
                    }
                } label: {
                    Label(
                        NSLocalizedString("settings.wiki_generate_missing", comment: "Generate missing wiki articles"),
                        systemImage: "plus.circle"
                    )
                }
                .disabled(isBusy || !settings.wikiEnabled || !hasKey)

                // Regenerates every article unconditionally, including ones
                // already up to date — the expensive option, kept separate
                // from "Generate Missing" above.
                Button {
                    Task {
                        await wiki.rebuildWiki()
                        wikiArticleCount = wiki.articleCount()
                    }
                } label: {
                    Label(
                        NSLocalizedString("settings.wiki_rebuild", comment: "Rebuild wiki"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isBusy || !settings.wikiEnabled || !hasKey)

                Button(role: .destructive) {
                    wiki.clearWiki()
                    wikiArticleCount = wiki.articleCount()
                } label: {
                    Label(
                        NSLocalizedString("settings.wiki_clear", comment: "Clear wiki"),
                        systemImage: "trash"
                    )
                }
                .disabled(isBusy || wikiArticleCount == 0)
            } header: {
                Text(NSLocalizedString("settings.wiki_title", comment: "Meeting wiki section title"))
            } footer: {
                Text(hasKey
                    ? NSLocalizedString("settings.wiki_footer", comment: "Meeting wiki footer")
                    : unavailableFooter)
            }
        }
        .navigationTitle(NSLocalizedString("settings.wiki_title", comment: "Meeting wiki"))
        .task { wikiArticleCount = wiki.articleCount() }
    }

    /// Determinate progress for the bulk run in flight, so a large library
    /// shows real "N of M" feedback instead of an indeterminate spinner the
    /// user has no way to gauge.
    @ViewBuilder
    private func bulkProgressRow(
        _ progress: (kind: WikiCoordinator.BulkOperationKind, completed: Int, total: Int)
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bulkProgressTitle(progress.kind))
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            ProgressView(value: Double(progress.completed), total: Double(progress.total))
            Text(String(
                format: NSLocalizedString("settings.wiki_bulk_progress", comment: "N of M meetings"),
                progress.completed, progress.total
            ))
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func bulkProgressTitle(_ kind: WikiCoordinator.BulkOperationKind) -> String {
        switch kind {
        case .missingOnly:
            return NSLocalizedString("settings.wiki_generating_missing", comment: "Generating missing wikis")
        case .rebuildAll:
            return NSLocalizedString("settings.wiki_rebuilding", comment: "Rebuilding wiki")
        }
    }
}
