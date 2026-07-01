//
//  AutoTagConfirmView.swift
//  Kurn
//
//  Sheet that previews tags suggested by the auto-tagging service and lets the
//  user apply them to the meeting.
//

import SwiftData
import SwiftUI

struct AutoTagConfirmView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var allTags: [Tag]

    let meeting: Meeting
    let suggestion: AutoTaggingService.Suggestion
    let onApply: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if existingTags.isEmpty && newTagNames.isEmpty {
                        Text(NSLocalizedString("tag.auto_suggest.empty", comment: "No tags suggested"))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(existingTags) { tag in
                            tagRow(tag)
                        }
                        ForEach(newTagNames, id: \.self) { name in
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 10, height: 10)
                                Text(name)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(NSLocalizedString("tag.suggested_new", comment: "new"))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                } header: {
                    Text(NSLocalizedString("tag.title", comment: "Tags"))
                } footer: {
                    Text(NSLocalizedString("tag.auto_suggest.disclaimer", comment: "Disclaimer"))
                }
            }
            .navigationTitle(NSLocalizedString("tag.auto_suggest", comment: "Suggest tags"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "Save")) {
                        onApply()
                        dismiss()
                    }
                    .disabled(existingTags.isEmpty && newTagNames.isEmpty)
                }
            }
        }
    }

    private var existingTags: [Tag] {
        allTags.filter { suggestion.tagIDs.contains($0.id) }
    }

    private var newTagNames: [String] {
        suggestion.newTagNames
    }

    private func tagRow(_ tag: Tag) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: tag.colorHex))
                .frame(width: 10, height: 10)
            Text(tag.name)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
        }
    }
}
