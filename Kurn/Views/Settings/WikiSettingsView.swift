//
//  WikiSettingsView.swift
//  Kurn
//
//  The LLM-generated meeting wiki: one condensed article per meeting, used by
//  the library-wide "Ask" so it can synthesize, compare, and count across
//  meetings. Unlike the on-device semantic index, building it calls the summary
//  AI provider, so it needs an explicit opt-in AND a configured API key: the
//  toggle stays disabled (with an explanatory footer) until a key exists.
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

    var body: some View {
        let hasKey = KeychainManager.shared.hasValue(for: settings.aiProvider.keychainAccount)
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
                    : NSLocalizedString("settings.wiki_needs_key", comment: "Meeting wiki needs an API key"))
            }
        }
        .navigationTitle(NSLocalizedString("settings.wiki_title", comment: "Meeting wiki"))
        .task { wikiArticleCount = wiki.articleCount() }
    }
}
