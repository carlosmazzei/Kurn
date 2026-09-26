//
//  SummaryTranslateLanguagePicker.swift
//  Kurn
//
//  Sheet shown when the user picks "Translate" on a summary chip: lists every
//  meeting language so they pick a target for the translation (Plaud-style,
//  mirrors SummaryTemplatePicker). The transcript's own language is
//  highlighted as a hint, but any target may be chosen.
//

import KurnCore
import SwiftUI

struct SummaryTranslateLanguagePicker: View {
    let suggestedLanguage: MeetingLanguage?
    let onSelect: (MeetingLanguage) -> Void

    @Environment(\.dismiss) private var dismiss

    private var languages: [MeetingLanguage] {
        MeetingLanguage.allCases.filter { $0 != .autoDetect }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(languages) { language in
                        Button {
                            onSelect(language)
                            dismiss()
                        } label: {
                            row(language)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(NSLocalizedString("detail.summary.choose_language", comment: "Choose translation target language"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
            }
        }
        // A fixed 7-language list is a quick pick, not a task that needs the
        // full screen.
        .presentationDetents([.medium])
    }

    private func row(_ language: MeetingLanguage) -> some View {
        let isSuggested = language == suggestedLanguage
        return HStack(spacing: 14) {
            Text(language.displayName)
                .font(Theme.calloutEmphasized)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
            if isSuggested {
                Text(NSLocalizedString("detail.summary.choose_language.suggested", comment: "Suggested language badge"))
                    .font(Theme.caption2)
                    .foregroundStyle(Theme.accent)
            }
        }
        .kurnCard()
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isSuggested ? Theme.accent : .clear, lineWidth: 1.5)
        )
    }
}
