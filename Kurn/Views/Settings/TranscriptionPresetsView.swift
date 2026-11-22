//
//  TranscriptionPresetsView.swift
//  Kurn
//
//  The Simple mode of Transcription settings: four named pipeline presets as
//  cards, plus a non-tappable "Custom" card when the current configuration
//  matches none of them. Applying a preset is not done here — the parent
//  `TranscriptionSettingsView` owns the consent sequencing (`pendingPreset`,
//  `advancePending`), because cloud presets go through the audio-upload
//  consent dialog and on-device presets through the model-download consent.
//

import SwiftUI

struct TranscriptionPresetsView: View {
    let current: TranscriptionPreset?
    let onSelect: (TranscriptionPreset) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if current == nil {
                    TranscriptionPresetCard(
                        title: NSLocalizedString("settings.preset.custom", comment: "Custom preset"),
                        subtitle: NSLocalizedString("settings.preset.custom_subtitle", comment: "Custom preset subtitle"),
                        rows: [],
                        isCurrent: true,
                        action: nil
                    )
                }
                ForEach(TranscriptionPreset.allCases) { preset in
                    TranscriptionPresetCard(
                        title: preset.title,
                        subtitle: preset.subtitle,
                        rows: preset.cardRows,
                        isCurrent: preset == current,
                        action: { onSelect(preset) }
                    )
                    .accessibilityIdentifier("settings.preset.\(preset.rawValue)")
                }
                Text(NSLocalizedString("settings.preset.footer", comment: "Word-error measurement disclaimer"))
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

struct TranscriptionPresetCard: View {
    let title: String
    let subtitle: String
    let rows: [(label: String, value: String)]
    let isCurrent: Bool
    let action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                        .font(Theme.subheadlineEmphasized)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.ink)
                            .accessibilityHidden(true)
                    }
                }
                Text(subtitle)
                    .font(Theme.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if !rows.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(rows, id: \.label) { row in
                            GridRow {
                                Text(row.label)
                                    .foregroundStyle(Theme.textSecondary)
                                Text(row.value)
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(Theme.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.ink, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
