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

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(templates) { template in
                        Button {
                            onSelect(template)
                            dismiss()
                        } label: {
                            row(template)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(NSLocalizedString("detail.summary.choose_template", comment: "Choose template"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
            }
        }
    }

    private func row(_ template: SummaryTemplate) -> some View {
        let isSelected = template.id == selectedID
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.fill)
                    .frame(width: 44, height: 44)
                Image(systemName: template.iconName)
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(template.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(template.summaryDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
        .kurnCard()
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSelected ? Theme.accent : .clear, lineWidth: 1.5)
        )
    }
}
