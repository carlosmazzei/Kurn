import SwiftData
import SwiftUI

/// The library's Knowledge reader, presented over the meetings list. Its
/// source selection belongs to the list (`meetingIDs`), so closing and
/// reopening the sheet keeps the meetings it was reading.
struct KnowledgeLibraryDestination: View {
    private enum ActiveSheet: Identifiable {
        case sources
        case settings
        var id: Self { self }
    }

    @Binding var meetingIDs: Set<UUID>
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: ActiveSheet?

    var body: some View {
        ZStack {
            if !settings.knowledgeEnabled {
                disabledState
            } else if meetingIDs.isEmpty {
                NavigationStack {
                    ContentUnavailableView {
                        Label(KnowledgeBrowserCopy.text("title"), systemImage: "book.pages")
                    } description: {
                        Text(KnowledgeBrowserCopy.text("choose_sources_detail"))
                    } actions: { chooseSourcesButton }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .knowledgeReadingSurface()
                    .navigationTitle(KnowledgeBrowserCopy.text("title"))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                        }
                    }
                }
            } else {
                KnowledgeBrowserView(meetingIDs: meetingIDs, showsDone: true, onChooseSources: { activeSheet = .sources })
                    .id(meetingIDs)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .sources:
                KnowledgeMeetingSelectionView(selectedIDs: meetingIDs) { meetingIDs = $0; activeSheet = nil }
            case .settings:
                NavigationStack {
                    KnowledgeSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(NSLocalizedString("common.done", comment: "Done")) { activeSheet = nil }
                            }
                        }
                }
            }
        }
    }

    private var disabledState: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(KnowledgeBrowserCopy.text("disabled_title"), systemImage: "book.pages")
            } description: {
                Text(KnowledgeBrowserCopy.text("disabled_detail"))
            } actions: {
                Button {
                    activeSheet = .settings
                } label: {
                    Label(
                        NSLocalizedString("recordings.open_settings", comment: "Open Settings"),
                        systemImage: "gearshape"
                    )
                    .font(Theme.calloutEmphasized)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.ink)
                .accessibilityIdentifier("knowledge.openSettings")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .knowledgeReadingSurface()
            .navigationTitle(KnowledgeBrowserCopy.text("title"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) { dismiss() }
                }
            }
        }
    }

    /// Choosing sources is the one thing this empty screen is for: the
    /// primary action style (Theme "Button language").
    private var chooseSourcesButton: some View {
        Button { activeSheet = .sources } label: {
            Label(KnowledgeBrowserCopy.text("choose_sources"), systemImage: "checklist")
                .font(Theme.calloutEmphasized)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.ink)
        .accessibilityIdentifier("knowledge.chooseSources")
    }
}

struct KnowledgeMeetingSelectionView: View {
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var selectedIDs: Set<UUID>
    let onDone: (Set<UUID>) -> Void
    private var allowedMeetings: [Meeting] { meetings.filter { settings.knowledgeControls?.allows($0.id) == true } }

    init(selectedIDs: Set<UUID>, onDone: @escaping (Set<UUID>) -> Void) {
        _selectedIDs = State(initialValue: selectedIDs)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(allowedMeetings) { meeting in
                        Button { toggle(meeting.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(meeting.id) ? "checkmark.circle.fill" : "circle")
                                    .font(Theme.title3)
                                    .foregroundStyle(selectedIDs.contains(meeting.id) ? Theme.link : Theme.textTertiary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: meeting.title).font(Theme.subheadline).foregroundStyle(Theme.textPrimary)
                                    Text(meeting.createdAt.meetingDisplay).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(selectedIDs.contains(meeting.id) ? .isSelected : [])
                        .accessibilityIdentifier("knowledge.sourceMeeting")
                        .disabled(!selectedIDs.contains(meeting.id) && selectedIDs.count >= 16)
                    }
                } header: {
                    Text(String(format: KnowledgeBrowserCopy.text("scope"), selectedIDs.count))
                } footer: { Text(KnowledgeBrowserCopy.text("choose_sources_detail")) }
            }
            .navigationTitle(KnowledgeBrowserCopy.text("choose_sources"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("common.done", comment: "Done")) {
                        onDone(selectedIDs.intersection(Set(allowedMeetings.map(\.id))))
                    }
                    .disabled(selectedIDs.count > 16)
                    .accessibilityIdentifier("knowledge.sources.done")
                }
            }
            .onChange(of: Set(allowedMeetings.map(\.id))) { _, ids in selectedIDs.formIntersection(ids) }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else if selectedIDs.count < 16 { selectedIDs.insert(id) }
    }
}
