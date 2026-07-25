//
//  SummarySettingsView.swift
//  Kurn
//
//  Which provider and model write summaries, and the templates that shape them.
//  Templates live together with the provider because picking one is the other
//  half of the same decision — persona and sections versus who runs it.
//

import SwiftUI

struct SummarySettingsView: View {
    @Environment(AppSettings.self) private var settings

    /// Key-revision counter from the root, so the configured-provider list
    /// reflects Keychain changes made on the Providers screen.
    let keyRevision: Int

    @State private var showingAddTemplate = false

    private var configuredProviders: [AIProvider] {
        _ = keyRevision
        return settings.configuredProviders
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section(NSLocalizedString("settings.summary", comment: "Summary")) {
                if configuredProviders.isEmpty {
                    Text(NSLocalizedString("settings.no_configured_providers", comment: "No configured providers"))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Picker(
                        NSLocalizedString("settings.provider", comment: "Provider"),
                        selection: $settings.aiProviderID
                    ) {
                        ForEach(configuredProviders) { Text($0.displayName).tag($0.id) }
                    }
                    SummaryModelPicker(settings: settings, provider: settings.aiProvider, revision: keyRevision)
                }
            }

            Section {
                ForEach(settings.summaryTemplates) { template in
                    NavigationLink {
                        TemplateEditor(
                            template: template,
                            onSave: { settings.updateTemplate($0) },
                            onDelete: { settings.removeTemplate(template) }
                        )
                    } label: {
                        TemplateRow(template: template)
                    }
                }
                Button {
                    showingAddTemplate = true
                } label: {
                    Label(NSLocalizedString("settings.add_template", comment: "Add Template"), systemImage: "plus")
                }
            } header: {
                Text(NSLocalizedString("settings.templates", comment: "Summary Templates"))
            } footer: {
                Text(NSLocalizedString("settings.templates_footer", comment: "Templates footer"))
            }
        }
        .navigationTitle(NSLocalizedString("settings.summary", comment: "Summary"))
        .sheet(isPresented: $showingAddTemplate) {
            NavigationStack {
                AddTemplateView { template in
                    settings.addTemplate(template)
                    showingAddTemplate = false
                }
            }
        }
    }
}
