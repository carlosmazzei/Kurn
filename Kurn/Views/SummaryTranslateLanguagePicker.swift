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

    /// The suggested language plus English when it differs — the two most
    /// likely targets, offered above the full list.
    private var suggested: [MeetingLanguage] {
        var picks: [MeetingLanguage] = []
        if let suggestedLanguage { picks.append(suggestedLanguage) }
        if !picks.contains(.english) {
            picks.append(.english)
        }
        return picks
    }

    var body: some View {
        NavigationStack {
            List {
                if !suggested.isEmpty {
                    Section(NSLocalizedString("detail.summary.translate.section.suggested", comment: "Suggested")) {
                        ForEach(suggested) { language in
                            row(language)
                        }
                    }
                }
                Section {
                    ForEach(languages) { language in
                        row(language)
                    }
                } header: {
                    Text(NSLocalizedString("detail.summary.translate.section.all", comment: "All"))
                } footer: {
                    Text(NSLocalizedString("detail.summary.translate.footer", comment: "Translation keeps the original"))
                }
            }
            .navigationTitle(NSLocalizedString("detail.summary.choose_language", comment: "Choose translation target language"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
            }
        }
        // A quick pick, not a task that needs the full screen.
        .presentationDetents([.medium, .large])
    }

    private func row(_ language: MeetingLanguage) -> some View {
        Button {
            onSelect(language)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Text(language.displayName)
                    .font(Theme.calloutEmphasized)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if language == suggestedLanguage {
                    Text(NSLocalizedString("detail.summary.choose_language.suggested", comment: "Suggested language badge"))
                        .font(Theme.caption2)
                        .foregroundStyle(Theme.link)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
