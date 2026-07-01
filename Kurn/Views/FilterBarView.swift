//
//  FilterBarView.swift
//  Kurn
//
//  Sheet for editing the active meetings-list filters: date range, tags,
//  transcription status, summary presence, and duration bounds.
//

import SwiftData
import SwiftUI

struct FilterBarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Binding var filter: MeetingFilter

    @Query(sort: \Tag.name) private var tags: [Tag]

    @State private var smartFolderName = ""
    @State private var showingSaveSheet = false
    @State private var saveError: AppError?

    var body: some View {
        NavigationStack {
            Form {
                dateSection
                tagSection
                statusSection
                summarySection
                durationSection
                if filter.isActive {
                    Section {
                        Button {
                            showingSaveSheet = true
                        } label: {
                            Label(
                                NSLocalizedString("smart_folder.save", comment: "Save as Smart Folder"),
                                systemImage: "sparkles.square.fill.on.square"
                            )
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .navigationTitle(NSLocalizedString("filter.title", comment: "Filters"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingSaveSheet) {
                saveSmartFolderSheet
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if filter.isActive {
                        Button(NSLocalizedString("filter.clear", comment: "Clear")) {
                            filter = MeetingFilter()
                        }
                    }
                }
            }
            .errorAlert($saveError)
        }
    }

    // MARK: - Sections

    private var dateSection: some View {
        Section(NSLocalizedString("filter.date", comment: "Date")) {
            Picker(
                NSLocalizedString("filter.date", comment: "Date"),
                selection: $filter.dateRange
            ) {
                ForEach(MeetingDateFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var tagSection: some View {
        Section(NSLocalizedString("filter.tags", comment: "Tags")) {
            if tags.isEmpty {
                Text(NSLocalizedString("tag.empty", comment: "No tags yet"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(tags) { tag in
                    let isSelected = filter.tagIDs.contains(tag.id)
                    Button {
                        toggleTag(tag)
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color(hex: tag.colorHex))
                                .frame(width: 10, height: 10)
                            Text(tag.name)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var statusSection: some View {
        Section(NSLocalizedString("filter.status", comment: "Status")) {
            ForEach(TranscriptionStatus.allCases, id: \.self) { status in
                let isSelected = filter.statuses.contains(status)
                Button {
                    toggleStatus(status)
                } label: {
                    HStack {
                        Text(status.displayName)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var summarySection: some View {
        Section(NSLocalizedString("filter.has_summary", comment: "Has summary")) {
            Picker(
                NSLocalizedString("filter.has_summary", comment: "Has summary"),
                selection: $filter.hasSummary
            ) {
                Text(NSLocalizedString("filter.all", comment: "All")).tag(nil as Bool?)
                Text(NSLocalizedString("filter.yes", comment: "Yes")).tag(true as Bool?)
                Text(NSLocalizedString("filter.no", comment: "No")).tag(false as Bool?)
            }
            .pickerStyle(.segmented)
        }
    }

    private var durationSection: some View {
        Section(NSLocalizedString("filter.duration", comment: "Duration")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(
                        String(
                            format: NSLocalizedString("filter.min_duration", comment: "Min duration"),
                            NSNumber(value: Int(filter.minDuration ?? 0))
                        )
                    )
                    Spacer()
                    Text(
                        String(
                            format: NSLocalizedString("filter.max_duration", comment: "Max duration"),
                            NSNumber(value: Int(filter.maxDuration ?? 3600))
                        )
                    )
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 12) {
                    TextField("Min", value: $filter.minDuration, format: .number)
                        .keyboardType(.numberPad)
                    TextField("Max", value: $filter.maxDuration, format: .number)
                        .keyboardType(.numberPad)
                }
            }
        }
    }

    // MARK: - Helpers

    private func toggleTag(_ tag: Tag) {
        if filter.tagIDs.contains(tag.id) {
            filter.tagIDs.remove(tag.id)
        } else {
            filter.tagIDs.insert(tag.id)
        }
    }

    private func toggleStatus(_ status: TranscriptionStatus) {
        if filter.statuses.contains(status) {
            filter.statuses.remove(status)
        } else {
            filter.statuses.insert(status)
        }
    }

    private var saveSmartFolderSheet: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("smart_folder.name", comment: "Name")) {
                    TextField(
                        NSLocalizedString("folder.name_placeholder", comment: "Name"),
                        text: $smartFolderName
                    )
                }
            }
            .navigationTitle(NSLocalizedString("smart_folder.save", comment: "Save as Smart Folder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) {
                        showingSaveSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.save", comment: "Save")) {
                        saveSmartFolder()
                    }
                    .disabled(smartFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func saveSmartFolder() {
        let name = smartFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let smartFolder = SmartFolder(name: name, filter: filter)
        modelContext.insert(smartFolder)
        do {
            try modelContext.save()
            showingSaveSheet = false
            dismiss()
        } catch {
            AppLog.persistence.atError.error("Failed to save smart folder: \(error, privacy: .public)")
            saveError = .persistenceFailed(
                NSLocalizedString("smart_folder.save_error", comment: "Could not save smart folder")
            )
        }
    }
}
