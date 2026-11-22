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

    @State private var showingAddTemplate = false

    /// Re-derives after any key change: `configuredSummaryProviders` reads
    /// through `settings.credentials`, which is observable.
    private var configuredProviders: [AIProvider] {
        settings.configuredSummaryProviders
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
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
                    if settings.aiProvider.kind == .appleOnDevice {
                        // There is exactly one on-device model and no `/models`
                        // endpoint to pick from, so this is static text rather
                        // than a picker.
                        LabeledContent(
                            NSLocalizedString("settings.model", comment: "Model"),
                            value: NSLocalizedString("settings.on_device_model_name", comment: "Apple Intelligence")
                        )
                    } else {
                        SummaryModelPicker(settings: settings, provider: settings.aiProvider)
                    }
                }
            } header: {
                Text(NSLocalizedString("settings.section.write_with", comment: "Write with"))
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
            } header: {
                HStack {
                    Text(NSLocalizedString("settings.templates", comment: "Summary Templates"))
                    Spacer()
                    Button(NSLocalizedString("settings.templates.new", comment: "New template")) {
                        showingAddTemplate = true
                    }
                    .accessibilityIdentifier("settings.templates.new")
                }
            } footer: {
                Text(NSLocalizedString("settings.templates_footer", comment: "Templates footer"))
            }

            Section {
                Toggle(
                    NSLocalizedString("settings.ai_title_cloud", comment: "Automatic titles with cloud providers"),
                    isOn: $settings.aiTitleCloudEnabled
                )
            } header: {
                Text(NSLocalizedString("settings.section.titles", comment: "Titles"))
            } footer: {
                Text(NSLocalizedString("settings.ai_title_cloud_footer", comment: "Explains automatic titles send the transcript to the cloud provider"))
            }

            Section {
                Toggle(
                    NSLocalizedString("settings.templates_sync", comment: "Sync Templates via iCloud"),
                    isOn: $settings.templatesSyncEnabled
                )
            } footer: {
                Text(NSLocalizedString("settings.templates_sync_footer", comment: "Templates sync footer"))
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
