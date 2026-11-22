//
//  FilterBarView.swift
//  Kurn
//
//  Sheet for editing the meetings-list filters as a draft: nothing applies
//  until the confirmation button ("Show N" — the count comes live from the
//  caller's `matchCount`) writes the draft back to the binding. Cancel leaves
//  the list untouched.
//

import KurnCore
import SwiftData
import SwiftUI

struct FilterBarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Binding var filter: MeetingFilter
    /// Counts meetings the bucket + quick chip allow that a candidate filter
    /// would keep; drives the confirmation button's "Show N" title.
    let matchCount: (MeetingFilter) -> Int

    /// The working copy; Cancel discards it, "Show N" writes it to `filter`.
    @State private var draft: MeetingFilter

    @Query(sort: \Tag.name) private var tags: [Tag]

    @State private var smartFolderName = ""
    @State private var showingSaveSheet = false
    @State private var saveError: AppError?

    init(filter: Binding<MeetingFilter>, matchCount: @escaping (MeetingFilter) -> Int) {
        _filter = filter
        self.matchCount = matchCount
        _draft = State(initialValue: filter.wrappedValue)
    }

    /// Duration presets offered by the "Longer than"/"Shorter than" menus.
    private static let durationOptions: [TimeInterval] = [300, 900, 1_800, 3_600, 7_200]

    var body: some View {
        NavigationStack {
            Form {
                periodSection
                tagSection
                statusSection
                durationSection
                if draft.isActive {
                    footerSection
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
                    Button {
                        filter = draft
                        dismiss()
                    } label: {
                        Text(
                            String(
                                format: NSLocalizedString("filter.show_count", comment: "Show N meetings"),
                                matchCount(draft)
                            )
                        )
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.ink)
                }
            }
            .errorAlert($saveError)
        }
        .presentationDetents([.large])
    }

    // MARK: - Sections

    private var periodSection: some View {
        Section(NSLocalizedString("filter.date", comment: "Period")) {
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(MeetingDateFilter.allCases) { option in
                    FilterChip(
                        title: option.title,
                        isSelected: draft.dateRange == option,
                        tint: draft.dateRange == option ? Theme.ink : .primary
                    ) {
                        draft.dateRange = option
                    }
                }
            }
        }
    }

    private var tagSection: some View {
        Section {
            if tags.isEmpty {
                Text(NSLocalizedString("tag.empty", comment: "No tags yet"))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(tags) { tag in
                    let isSelected = draft.tagIDs.contains(tag.id)
                    Button {
                        draft.toggleTag(tag.id)
                    } label: {
                        selectionRow(
                            text: tag.name,
                            leading: AnyView(
                                Circle()
                                    .fill(Color(hex: tag.colorHex))
                                    .frame(width: 10, height: 10)
                            ),
                            isSelected: isSelected
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text(NSLocalizedString("filter.tags", comment: "Tags"))
                Spacer()
                if !draft.tagIDs.isEmpty {
                    Button(NSLocalizedString("filter.clear", comment: "Clear")) {
                        draft.tagIDs = []
                    }
                }
            }
        }
    }

    private var statusSection: some View {
        Section(NSLocalizedString("filter.status", comment: "Status")) {
            ForEach(TranscriptionStatus.allCases, id: \.self) { status in
                let isSelected = draft.statuses.contains(status)
                Button {
                    draft.toggleStatus(status)
                } label: {
                    selectionRow(text: status.displayName, leading: nil, isSelected: isSelected)
                }
                .buttonStyle(.plain)
            }
            summaryRow(
                title: NSLocalizedString("filter.with_summary", comment: "With summary"),
                value: true
            )
            summaryRow(
                title: NSLocalizedString("filter.without_summary", comment: "Without summary"),
                value: false
            )
        }
    }

    /// With/Without summary: mutually exclusive toggles over `hasSummary`;
    /// tapping the checked one clears the condition.
    private func summaryRow(title: String, value: Bool) -> some View {
        let isSelected = draft.hasSummary == value
        return Button {
            draft.hasSummary = isSelected ? nil : value
        } label: {
            selectionRow(text: title, leading: nil, isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }

    private var durationSection: some View {
        Section(NSLocalizedString("filter.duration", comment: "Duration")) {
            durationRow(
                title: NSLocalizedString("filter.longer_than", comment: "Longer than"),
                value: draft.minDuration
            ) { draft.minDuration = $0 }
            durationRow(
                title: NSLocalizedString("filter.shorter_than", comment: "Shorter than"),
                value: draft.maxDuration
            ) { draft.maxDuration = $0 }
        }
    }

    private func durationRow(
        title: String,
        value: TimeInterval?,
        set: @escaping (TimeInterval?) -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Menu {
                Button {
                    set(nil)
                } label: {
                    durationMenuLabel(NSLocalizedString("filter.duration.any", comment: "Any"), checked: value == nil)
                }
                ForEach(Self.durationOptions, id: \.self) { seconds in
                    Button {
                        set(seconds)
                    } label: {
                        durationMenuLabel(durationText(seconds), checked: value == seconds)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value.map(durationText) ?? NSLocalizedString("filter.duration.any", comment: "Any"))
                        .foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func durationMenuLabel(_ title: String, checked: Bool) -> some View {
        Label {
            Text(title)
        } icon: {
            if checked {
                Image(systemName: "checkmark")
            }
        }
    }

    /// "5 min"/"2 hr" labels for the duration presets — formatted, never a
    /// hard-coded "min" string.
    private func durationText(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated,
                              maximumUnitCount: 1))
    }

    private var footerSection: some View {
        Section {
            Button {
                showingSaveSheet = true
            } label: {
                Label(
                    NSLocalizedString("smart_folder.save", comment: "Save as Smart Folder"),
                    systemImage: "sparkles.square.fill.on.square"
                )
                .foregroundStyle(Theme.link)
            }
            Button {
                draft = MeetingFilter()
            } label: {
                Text(NSLocalizedString("filter.clear_all", comment: "Clear all filters"))
            }
        }
    }

    /// Shared row: optional leading decoration, title, blue checkmark when
    /// selected.
    private func selectionRow(text: String, leading: AnyView?, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            if let leading { leading }
            Text(text)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.link)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Smart folder sheet

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
        do throws(AppError) {
            try MeetingLibrary(context: modelContext).createSmartFolder(name: name, filter: draft)
            showingSaveSheet = false
            dismiss()
        } catch {
            // Already logged (code public, detail private) by `saveOrError()`.
            saveError = .persistenceFailed(
                NSLocalizedString("smart_folder.save_error", comment: "Could not save smart folder")
            )
        }
    }
}
