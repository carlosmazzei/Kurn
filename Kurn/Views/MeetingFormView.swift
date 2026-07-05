//
//  MeetingFormView.swift
//  Kurn
//
//  Create or edit a meeting: title, notes, and the transcription language.
//

import SwiftData
import SwiftUI

struct MeetingFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    /// When non-nil, the form edits an existing meeting; otherwise it creates.
    var meeting: Meeting?

    @State private var title = ""
    @State private var notes = ""
    @State private var language: MeetingLanguage = .autoDetect
    @State private var initialized = false
    @State private var showingTagPicker = false
    /// Set when saving fails, so the failure surfaces and the form stays open.
    @State private var saveError: AppError?

    var body: some View {
        Form {
            Section(NSLocalizedString("form.title_section", comment: "Title")) {
                TextField(
                    NSLocalizedString("form.title_placeholder", comment: "Title"),
                    text: $title
                )
            }
            Section(NSLocalizedString("form.notes_section", comment: "Notes")) {
                TextField(
                    NSLocalizedString("form.notes_placeholder", comment: "Notes"),
                    text: $notes,
                    axis: .vertical
                )
                .lineLimit(3...8)
            }
            Section(NSLocalizedString("form.language_section", comment: "Language")) {
                Picker(
                    NSLocalizedString("form.language", comment: "Language"),
                    selection: $language
                ) {
                    ForEach(MeetingLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }
            if let meeting {
                Section(NSLocalizedString("tag.title", comment: "Tags")) {
                    Button {
                        showingTagPicker = true
                    } label: {
                        HStack {
                            if meeting.tags.isEmpty {
                                Text(NSLocalizedString("meetings.tag.add", comment: "Add tag"))
                                    .foregroundStyle(Theme.textSecondary)
                            } else {
                                TagChipsView(tags: meeting.tags)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showingTagPicker) {
            if let meeting {
                NavigationStack { TagPickerView(meeting: meeting) }
            }
        }
        .navigationTitle(
            meeting == nil
                ? NSLocalizedString("form.new_title", comment: "New Meeting")
                : NSLocalizedString("form.edit_title", comment: "Edit Meeting")
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("common.save", comment: "Save")) { save() }
            }
        }
        .onAppear(perform: setupIfNeeded)
        .errorAlert($saveError)
    }

    private func setupIfNeeded() {
        guard !initialized else { return }
        initialized = true
        if let meeting {
            title = meeting.title
            notes = meeting.notes
            language = meeting.language
        } else {
            title = String(
                format: NSLocalizedString("meeting.default_title", comment: "Default title"),
                Date().isoDay
            )
            language = settings.defaultLanguage
        }
    }

    private func save() {
        if let meeting {
            meeting.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            meeting.notes = notes
            meeting.language = language
            if let failure = modelContext.saveOrError() {
                saveError = failure
                return
            }
        } else {
            let viewModel = MeetingsViewModel(modelContext: modelContext)
            viewModel.createMeeting(title: title, notes: notes, language: language)
            if let failure = viewModel.error {
                saveError = failure
                return
            }
        }
        dismiss()
    }
}
