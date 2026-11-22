//
//  MeetingFormView.swift
//  Kurn
//
//  Create or edit a meeting: title, notes, and the transcription language.
//

import KurnCore
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
    @State private var showingFolderPicker = false
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
            Section {
                Picker(
                    NSLocalizedString("form.language", comment: "Language"),
                    selection: $language
                ) {
                    ForEach(MeetingLanguage.allCases) { lang in
                        LanguagePickerRow(
                            language: lang, engine: settings.transcriptionEngine, fluidAudioASRModel: settings.fluidAudioASRModel
                        ).tag(lang)
                    }
                }
            } header: {
                Text(NSLocalizedString("form.language_section", comment: "Language"))
            } footer: {
                Text(NSLocalizedString("settings.language_support_footer", comment: "Explains the unsupported-language warning icon"))
            }
            if let meeting {
                Section(NSLocalizedString("form.organisation_section", comment: "Organisation")) {
                    Button {
                        showingFolderPicker = true
                    } label: {
                        HStack {
                            Text(NSLocalizedString("folder.title", comment: "Folder"))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(meeting.folder?.name ?? NSLocalizedString("folder.inbox", comment: "Inbox"))
                                .foregroundStyle(Theme.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    Button {
                        showingTagPicker = true
                    } label: {
                        HStack {
                            Text(NSLocalizedString("tag.title", comment: "Tags"))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if meeting.tags.isEmpty {
                                Text(NSLocalizedString("meetings.tag.add", comment: "Add tag"))
                                    .foregroundStyle(Theme.textSecondary)
                            } else {
                                Text(meeting.tags.map(\.name).sorted().joined(separator: ", "))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(.footnote, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section(NSLocalizedString("form.notes_section", comment: "Notes")) {
                TextField(
                    NSLocalizedString("form.notes_placeholder", comment: "Notes"),
                    text: $notes,
                    axis: .vertical
                )
                .lineLimit(3...8)
            }
        }
        .sheet(isPresented: $showingTagPicker) {
            if let meeting {
                NavigationStack { TagPickerView(meeting: meeting) }
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            if let meeting {
                FolderPickerView(meeting: meeting)
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
                    .inkProminent()
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
                Date().titleStamp
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
            do throws(AppError) {
                try MeetingLibrary(context: modelContext)
                    .createMeeting(title: title, notes: notes, language: language)
            } catch {
                saveError = error
                return
            }
        }
        dismiss()
    }
}
