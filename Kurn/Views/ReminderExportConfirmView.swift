//
//  ReminderExportConfirmView.swift
//  Kurn
//
//  Sheet that previews a summary section's items before they're written to
//  Reminders, mirroring `AutoTagConfirmView`'s review-before-apply pattern —
//  nothing is created until the user confirms a selection here.
//

import KurnCore
import SwiftUI

struct ReminderExportConfirmView: View {
    @Environment(\.dismiss) private var dismiss

    let section: SummarySection
    let onApply: ([String]) -> Void

    @State private var selectedItems: Set<Int>

    init(section: SummarySection, onApply: @escaping ([String]) -> Void) {
        self.section = section
        self.onApply = onApply
        _selectedItems = State(initialValue: Set(section.items.indices))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                        itemRow(index: index, text: item)
                    }
                } header: {
                    Text(NSLocalizedString("reminders.export.title", comment: "Send to Reminders"))
                } footer: {
                    Text(NSLocalizedString("reminders.export.disclaimer", comment: "Reminders export disclaimer"))
                }
            }
            .navigationTitle(NSLocalizedString("reminders.export.title", comment: "Send to Reminders"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "Save")) {
                        onApply(selectedTexts)
                        dismiss()
                    }
                    .disabled(selectedItems.isEmpty)
                }
            }
        }
    }

    private var selectedTexts: [String] {
        section.items.enumerated()
            .filter { selectedItems.contains($0.offset) }
            .map(\.element)
    }

    private func itemRow(index: Int, text: String) -> some View {
        Button {
            if selectedItems.contains(index) {
                selectedItems.remove(index)
            } else {
                selectedItems.insert(index)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedItems.contains(index) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedItems.contains(index) ? Theme.accent : Theme.textTertiary)
                    .accessibilityHidden(true)
                Text(text)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}
