import SwiftData
import SwiftUI

struct KnowledgeLibraryDestination: View {
    @State private var meetingIDs: Set<UUID>
    @State private var showingSources = false

    init(initialMeetingIDs: Set<UUID> = []) { _meetingIDs = State(initialValue: initialMeetingIDs) }

    var body: some View {
        ZStack {
            if meetingIDs.isEmpty {
                NavigationStack {
                    ContentUnavailableView {
                        Label(KnowledgeBrowserCopy.text("title"), systemImage: "book.pages")
                    } description: {
                        Text(KnowledgeBrowserCopy.text("choose_sources_detail"))
                    } actions: { chooseSourcesButton }
                    .navigationTitle(KnowledgeBrowserCopy.text("title"))
                    .toolbar(.hidden, for: .tabBar)
                }
            } else {
                KnowledgeBrowserView(meetingIDs: meetingIDs, showsDone: false, onChooseSources: { showingSources = true })
                    .id(meetingIDs)
            }
        }
        .sheet(isPresented: $showingSources) {
            KnowledgeMeetingSelectionView(selectedIDs: meetingIDs) { meetingIDs = $0; showingSources = false }
        }
    }

    private var chooseSourcesButton: some View {
        Button { showingSources = true } label: {
            Label(KnowledgeBrowserCopy.text("choose_sources"), systemImage: "checklist")
        }
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
                            HStack {
                                Image(systemName: selectedIDs.contains(meeting.id) ? "checkmark.circle.fill" : "circle")
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(verbatim: meeting.title)
                                    Text(meeting.createdAt.meetingDisplay).font(.footnote)
                                }
                            }
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
