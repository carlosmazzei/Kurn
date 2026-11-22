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
                    Text(NSLocalizedString("tag.auto_suggest.lead", comment: "Suggestion lead"))
                        .foregroundStyle(Theme.textSecondary)
                }

                if existingTags.isEmpty && suggestion.newTagNames.isEmpty {
                    Section {
                        Text(NSLocalizedString("tag.auto_suggest.empty", comment: "No tags suggested"))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    if !existingTags.isEmpty {
                        Section(NSLocalizedString("tag.auto_suggest.section.existing", comment: "Existing")) {
                            ForEach(existingTags) { tag in
                                tagRow(tag)
                            }
                        }
                    }
                    if !suggestion.newTagNames.isEmpty {
                        Section(NSLocalizedString("tag.auto_suggest.section.new", comment: "New")) {
                            ForEach(suggestion.newTagNames, id: \.self) { name in
                                Button {
                                    toggleNewTag(name)
                                } label: {
                                    HStack(spacing: 12) {
                                        selectionIndicator(selectedNewTagNames.contains(name))
                                        Image(systemName: "sparkles")
                                            .foregroundStyle(Theme.textSecondary)
                                            .accessibilityHidden(true)
                                        Text(name)
                                            .foregroundStyle(Theme.textPrimary)
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section {
                    Text(NSLocalizedString("tag.auto_suggest.disclaimer", comment: "Disclaimer"))
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .navigationTitle(NSLocalizedString("tag.auto_suggest", comment: "Suggest tags"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        String(
                            format: NSLocalizedString("tag.auto_suggest.apply_count", comment: "Apply count"),
                            selectedTagIDs.count + selectedNewTagNames.count
                        )
                    ) {
                        onApply(selectedSuggestion)
                        dismiss()
                    }
                    .inkProminent()
                    .disabled(selectedTagIDs.isEmpty && selectedNewTagNames.isEmpty)
                }
            }
        }
        // A handful of suggested tags is a quick review task, not one that
        // needs the full screen.
        .presentationDetents([.medium, .large])
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
            .foregroundStyle(selected ? Theme.link : Theme.textTertiary)
            .accessibilityHidden(true)
    }
}
