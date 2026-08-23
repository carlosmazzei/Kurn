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
    let onApply: (AutoTaggingService.Suggestion) -> Void

    @State private var selectedTagIDs: Set<UUID>
    @State private var selectedNewTagNames: Set<String>

    init(
        meeting: Meeting,
        suggestion: AutoTaggingService.Suggestion,
        onApply: @escaping (AutoTaggingService.Suggestion) -> Void
    ) {
        self.meeting = meeting
        self.suggestion = suggestion
        self.onApply = onApply
        _selectedTagIDs = State(initialValue: Set(suggestion.tagIDs))
        _selectedNewTagNames = State(initialValue: Set(suggestion.newTagNames))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if existingTags.isEmpty && suggestion.newTagNames.isEmpty {
                        Text(NSLocalizedString("tag.auto_suggest.empty", comment: "No tags suggested"))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        ForEach(existingTags) { tag in
                            tagRow(tag)
                        }
                        ForEach(suggestion.newTagNames, id: \.self) { name in
                            Button {
                                toggleNewTag(name)
                            } label: {
                                HStack(spacing: 12) {
                                    selectionIndicator(selectedNewTagNames.contains(name))
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(Theme.accent)
                                        .accessibilityHidden(true)
                                    Text(name)
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text(NSLocalizedString("tag.suggested_new", comment: "new"))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(NSLocalizedString("tag.title", comment: "Tags"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("tag.auto_suggest.selection_hint", comment: "Selection hint"))
                        Text(NSLocalizedString("tag.auto_suggest.disclaimer", comment: "Disclaimer"))
                    }
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
                        onApply(selectedSuggestion)
                        dismiss()
                    }
                    .disabled(selectedTagIDs.isEmpty && selectedNewTagNames.isEmpty)
                }
            }
        }
    }

    private var existingTags: [Tag] {
        allTags.filter { suggestion.tagIDs.contains($0.id) }
    }

    private func tagRow(_ tag: Tag) -> some View {
        Button {
            if selectedTagIDs.contains(tag.id) {
                selectedTagIDs.remove(tag.id)
            } else {
                selectedTagIDs.insert(tag.id)
            }
        } label: {
            HStack(spacing: 12) {
                selectionIndicator(selectedTagIDs.contains(tag.id))
                Circle()
                    .fill(Color(hex: tag.colorHex))
                    .frame(width: 10, height: 10)
                Text(tag.name)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private var selectedSuggestion: AutoTaggingService.Suggestion {
        AutoTaggingService.Suggestion(
            tagIDs: suggestion.tagIDs.filter(selectedTagIDs.contains),
            newTagNames: suggestion.newTagNames.filter(selectedNewTagNames.contains)
        )
    }

    private func toggleNewTag(_ name: String) {
        if selectedNewTagNames.contains(name) {
            selectedNewTagNames.remove(name)
        } else {
            selectedNewTagNames.insert(name)
        }
    }

    private func selectionIndicator(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
            .accessibilityHidden(true)
    }
}
