//
//  TemplateEditorView.swift
//  Kurn
//
//  Create/edit screens for summary templates, plus the settings list row. Mirrors
//  the provider editor pattern: built-in presets can be tuned (instructions and
//  sections) but not renamed or deleted; custom templates are fully editable.
//

import SwiftUI

/// Row shown in the settings templates list.
struct TemplateRow: View {
    let template: SummaryTemplate

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: template.iconName)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(width: 32, height: 32)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(template.displayName).font(.system(size: 15, weight: .semibold))
                Text(template.isBuiltIn
                     ? NSLocalizedString("settings.template.builtin", comment: "Preset")
                     : NSLocalizedString("settings.template.custom", comment: "Custom"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// Edit an existing template. Built-ins keep their name; custom templates are
/// fully editable and can be deleted.
struct TemplateEditor: View {
    let template: SummaryTemplate
    let onSave: (SummaryTemplate) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var sections: [String] = []
    @State private var showingDeleteConfirm = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            TemplateFields(
                name: $name,
                instructions: $instructions,
                sections: $sections,
                nameEditable: !template.isBuiltIn
            )

            if !template.isBuiltIn {
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Text(NSLocalizedString("settings.delete_template", comment: "Delete Template"))
                    }
                }
            }
        }
        .navigationTitle(template.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.save", comment: "Save")) {
                    var updated = template
                    if !template.isBuiltIn {
                        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    updated.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.sections = TemplateFields.cleanedSections(sections)
                    onSave(updated)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            name = template.displayName
            instructions = template.instructions
            sections = template.sections
        }
        .kurnDialog(
            isPresented: $showingDeleteConfirm,
            iconSystemName: "trash.fill",
            iconTint: Theme.accent,
            title: NSLocalizedString("settings.delete_template.confirm", comment: "Delete template?"),
            message: template.displayName,
            primaryTitle: NSLocalizedString("settings.delete_template", comment: "Delete Template"),
            primaryRole: .destructive,
            primaryAction: {
                onDelete()
                dismiss()
            },
            secondaryTitle: NSLocalizedString("common.cancel", comment: "Cancel")
        )
    }
}

/// Create a new custom template.
struct AddTemplateView: View {
    let onAdd: (SummaryTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var sections: [String] = [""]

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            TemplateFields(
                name: $name,
                instructions: $instructions,
                sections: $sections,
                nameEditable: true
            )
        }
        .navigationTitle(NSLocalizedString("settings.add_template", comment: "Add Template"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.save", comment: "Save")) {
                    let template = SummaryTemplate.custom(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
                        sections: TemplateFields.cleanedSections(sections)
                    )
                    onAdd(template)
                }
                .disabled(!canSave)
            }
        }
    }
}

/// Shared form body for adding/editing a template.
private struct TemplateFields: View {
    @Binding var name: String
    @Binding var instructions: String
    @Binding var sections: [String]
    let nameEditable: Bool

    static func cleanedSections(_ raw: [String]) -> [String] {
        raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        Section {
            TextField(NSLocalizedString("settings.template_name", comment: "Template name"), text: $name)
                .disabled(!nameEditable)
        } header: {
            Text(NSLocalizedString("settings.template_name", comment: "Template name"))
        }

        Section {
            TextEditor(text: $instructions)
                .frame(minHeight: 120)
        } header: {
            Text(NSLocalizedString("settings.template_instructions", comment: "Instructions"))
        } footer: {
            Text(NSLocalizedString("settings.template_instructions_footer", comment: "Instructions footer"))
        }

        Section {
            ForEach(sections.indices, id: \.self) { index in
                TextField(
                    NSLocalizedString("settings.template_section", comment: "Section"),
                    text: $sections[index]
                )
            }
            .onDelete { sections.remove(atOffsets: $0) }
            Button {
                sections.append("")
            } label: {
                Label(NSLocalizedString("settings.template_add_section", comment: "Add Section"), systemImage: "plus")
            }
        } header: {
            Text(NSLocalizedString("settings.template_sections", comment: "Sections"))
        } footer: {
            Text(NSLocalizedString("settings.template_sections_footer", comment: "Sections footer"))
        }
    }
}
