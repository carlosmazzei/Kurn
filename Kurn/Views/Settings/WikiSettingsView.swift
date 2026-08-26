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

    /// Count of stored articles, refreshed on appear and after a rebuild/clear.
    @State private var wikiArticleCount = 0
    /// True while a rebuild is running, so the buttons show progress and can't
    /// be re-triggered.
    @State private var isRebuildingWiki = false

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
                Button {
                    Task {
                        isRebuildingWiki = true
                        await wiki.rebuildWiki()
                        wikiArticleCount = wiki.articleCount()
                        isRebuildingWiki = false
                    }
                } label: {
                    if isRebuildingWiki {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("settings.wiki_rebuilding", comment: "Rebuilding wiki"))
                        }
                    } else {
                        Label(
                            NSLocalizedString("settings.wiki_rebuild", comment: "Rebuild wiki"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
                .disabled(isRebuildingWiki || !settings.wikiEnabled || !hasKey)
                Button(role: .destructive) {
                    wiki.clearWiki()
                    wikiArticleCount = wiki.articleCount()
                } label: {
                    Label(
                        NSLocalizedString("settings.wiki_clear", comment: "Clear wiki"),
                        systemImage: "trash"
                    )
                }
                .disabled(isRebuildingWiki || wikiArticleCount == 0)
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
}
