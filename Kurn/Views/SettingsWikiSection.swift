//
//  SettingsWikiSection.swift
//  Kurn
//
//  The Settings section for the LLM-generated meeting wiki, split into its own
//  `SettingsView` extension to keep `SettingsSections.swift` under SwiftLint's
//  length limit. The wiki builds via the summary LLM provider, so it needs an
//  explicit opt-in AND a configured API key: the toggle is disabled (with an
//  explanatory footer) until a key exists for the current summary provider.
//

import SwiftUI

extension SettingsView {

    @ViewBuilder
    func wikiSection(settings: AppSettings) -> some View {
        // Editing a key elsewhere in Settings bumps `keyRevision`, which
        // re-evaluates the whole form (and this `hasKey`) so the toggle
        // enables/disables in step.
        let hasKey = KeychainManager.shared.hasValue(for: settings.aiProvider.keychainAccount)
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
        .task { wikiArticleCount = wiki.articleCount() }
    }
}
