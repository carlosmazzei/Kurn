//
//  TagsSettingsView.swift
//  Kurn
//
//  Tag management plus the opt-in auto-tagging pass, which asks the configured
//  summary provider to suggest tags from a transcript excerpt.
//

import SwiftUI

struct TagsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                NavigationLink {
                    TagManagementView()
                } label: {
                    Label(
                        NSLocalizedString("tag.manage", comment: "Manage Tags"),
                        systemImage: "tag"
                    )
                }
                Toggle(
                    NSLocalizedString("settings.auto_tagging", comment: "Auto-tagging"),
                    isOn: $settings.autoTaggingEnabled
                )
            } footer: {
                Text(NSLocalizedString("settings.auto_tagging_footer", comment: "Auto-tagging footer"))
            }
        }
        .navigationTitle(NSLocalizedString("tag.title", comment: "Tags"))
    }
}
