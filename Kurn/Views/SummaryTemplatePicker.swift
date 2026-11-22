//
//  SummaryTemplatePicker.swift
//  Kurn
//
//  Sheet shown when the user taps "Generate Summary": lists the configured
//  summary templates so they pick one per summarization (Plaud-style). The last
//  used template is highlighted.
//

import SwiftUI

struct SummaryTemplatePicker: View {
    let templates: [SummaryTemplate]
    let selectedID: String
    let onSelect: (SummaryTemplate) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showingModelPicker = false
    @State private var showingTemplateSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(templates) { template in
                        Button {
                            onSelect(template)
                            dismiss()
                        } label: {
                            row(template)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text(NSLocalizedString("summary.template.footer", comment: "Summaries are kept"))
                }

                Section {
                    Button { showingModelPicker = true } label: {
                        HStack {
                            Text(modelLine)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                } header: {
                    Text(NSLocalizedString("settings.section.write_with", comment: "Write with"))
                } footer: {
                    Text(NSLocalizedString("summary.model.ask_footer", comment: "The same model is used by Ask"))
                }

                Section {
                    Button { showingTemplateSettings = true } label: {
                        Text(NSLocalizedString("summary.template.manage", comment: "Manage summary templates"))
                            .foregroundStyle(Theme.link)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle(NSLocalizedString("detail.summary.choose_template", comment: "Choose template"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingModelPicker) {
            NavigationStack {
                Form {
                    Section {
                        SummaryModelPicker(settings: settings, provider: settings.aiProvider)
                    } header: {
                        Text(NSLocalizedString("settings.section.write_with", comment: "Write with"))
                    }
                }
                .navigationTitle(NSLocalizedString("settings.model", comment: "Model"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(NSLocalizedString("common.done", comment: "Done")) { showingModelPicker = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showingTemplateSettings) {
            NavigationStack {
                SummarySettingsView()
            }
        }
        // A short template list fits `.medium`; a longer user-defined set can
        // grow into `.large` rather than always opening full-height for a
        // quick "pick one" task, matching `MeetingShareSelectionView`.
        .presentationDetents([.medium, .large])
    }

    /// "<provider> · <model>"; on-device Apple has a single fixed model.
    private var modelLine: String {
        let provider = settings.aiProvider
        let model = provider.kind == .appleOnDevice
            ? NSLocalizedString("settings.on_device_model_name", comment: "Apple Intelligence")
            : settings.summaryModel(for: provider)
        return "\(provider.displayName) · \(model)"
    }

    private func row(_ template: SummaryTemplate) -> some View {
        let isSelected = template.id == selectedID
        return HStack(spacing: 14) {
            Image(systemName: template.iconName)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(template.displayName)
                    .font(Theme.calloutEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                Text(template.summaryDescription)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.link)
                    .accessibilityHidden(true)
            }
        }
    }
}
