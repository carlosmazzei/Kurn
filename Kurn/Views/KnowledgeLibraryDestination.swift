import KurnCore
import SwiftData
import SwiftUI

/// The library's wiki reader, presented over the meetings list. Its
/// source selection belongs to the list (`meetingIDs`), so closing and
/// reopening the sheet keeps the meetings it was reading; a fresh open
/// preselects this week's allowed meetings.
struct KnowledgeLibraryDestination: View {
    private enum ActiveSheet: Identifiable {
        case sources
        case settings
        var id: Self { self }
    }

    @Binding var meetingIDs: Set<UUID>
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var activeSheet: ActiveSheet?

    private var allowedMeetings: [Meeting] {
        meetings.filter { settings.knowledgeControls?.allows($0.id) == true }
    }

    /// What the scope chip names: "Today" / "This week" when the selection is
    /// exactly that day/week, else the count.
    private var scopeLabel: String {
        let calendar = Calendar.current
        let selected = allowedMeetings.filter { meetingIDs.contains($0.id) }
        if !selected.isEmpty, selected.allSatisfy({ calendar.isDateInToday($0.createdAt) }) {
            return KnowledgeBrowserCopy.text("scope_today")
        }
        if !selected.isEmpty,
           let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start,
           selected.allSatisfy({ $0.createdAt >= weekStart }) {
            return KnowledgeBrowserCopy.text("scope_week")
        }
        return knowledgeCountText("knowledge.count.meeting", meetingIDs.count)
    }

    var body: some View {
        ZStack {
            if !settings.knowledgeEnabled {
                disabledState
            } else if meetingIDs.isEmpty {
                NavigationStack {
                    ContentUnavailableView {
                        Label(KnowledgeBrowserCopy.text("title"), systemImage: "book")
                    } description: {
                        Text(NSLocalizedString("detail.knowledge.empty", comment: "No contributions"))
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
            } else {
                KnowledgeBrowserView(meetingIDs: meetingIDs, showsDone: true, scopeLabel: scopeLabel,
                                     onChooseSources: { activeSheet = .sources },
                                     onOpenSettings: { activeSheet = .settings })
                    .id(meetingIDs)
            }
        }
        // Meetings resolve asynchronously; re-check when the allowed set or
        // the enabled flag changes, not only on first appear — a scoped
        // meeting deleted meanwhile gets dropped from the selection here.
        .task(id: "\(settings.knowledgeEnabled):\(allowedMeetings.map(\.id.uuidString).sorted())") {
            reconcileScope()
        }
        .onAppear { reconcileScope() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .sources:
                KnowledgeMeetingSelectionView(selectedIDs: meetingIDs, allowedIDs: allowedMeetings.map(\.id),
                                              meetings: allowedMeetings) { meetingIDs = $0; activeSheet = nil }
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

    /// Drops scoped meetings that no longer exist or lost their allowance;
    /// a selection left empty falls back to this week's meetings (or the
    /// newest when the week is empty), never to a picker screen.
    private func reconcileScope() {
        guard settings.knowledgeEnabled else { return }
        let reconciled = WikiDefaultScope.reconcile(
            selected: meetingIDs,
            candidates: allowedMeetings.map { (id: $0.id, createdAt: $0.createdAt) },
            now: Date())
        if reconciled != meetingIDs { meetingIDs = reconciled }
    }

    private var disabledState: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(KnowledgeBrowserCopy.text("disabled_title"), systemImage: "book")
            } description: {
                Text(KnowledgeBrowserCopy.text("disabled_detail"))
            } actions: {
                Button {
                    activeSheet = .settings
                } label: {
                    Text(KnowledgeBrowserCopy.text("enable"))
                        .font(Theme.calloutEmphasized)
                }
                .inkProminent()
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
}

struct KnowledgeMeetingSelectionView: View {
    private enum ScopeMode { case today, week, choose }

    let allowedIDs: [UUID]
    let meetings: [Meeting]
    let onDone: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: Set<UUID>
    @State private var mode: ScopeMode = .choose

    init(selectedIDs: Set<UUID>, allowedIDs: [UUID], meetings: [Meeting], onDone: @escaping (Set<UUID>) -> Void) {
        self.allowedIDs = allowedIDs
        self.meetings = meetings
        self.onDone = onDone
        _selectedIDs = State(initialValue: selectedIDs)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(KnowledgeBrowserCopy.text("choose_sources"), selection: $mode) {
                        Text(KnowledgeBrowserCopy.text("scope_today")).tag(ScopeMode.today)
                        Text(KnowledgeBrowserCopy.text("scope_week")).tag(ScopeMode.week)
                        Text(NSLocalizedString("knowledge.sources.choose", comment: "Manual source choice")).tag(ScopeMode.choose)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("knowledge.sources.scope")
                }
                Section {
                    ForEach(meetings) { meeting in
                        Button { toggle(meeting.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(meeting.id) ? "checkmark.circle.fill" : "circle")
                                    .font(Theme.title3)
                                    .foregroundStyle(selectedIDs.contains(meeting.id) ? Theme.link : Theme.textTertiary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: meeting.title).font(Theme.subheadline).foregroundStyle(Theme.textPrimary)
                                    Text(meeting.createdAt.relativeDay).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(selectedIDs.contains(meeting.id) ? .isSelected : [])
                        .accessibilityIdentifier("knowledge.sourceMeeting")
                        .disabled(!selectedIDs.contains(meeting.id) && selectedIDs.count >= 16)
                    }
                } footer: { Text(KnowledgeBrowserCopy.text("choose_sources_detail")) }
            }
            .navigationTitle(KnowledgeBrowserCopy.text("choose_sources"))
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.large])
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(format: NSLocalizedString("knowledge.sources.use", comment: "Use selection"), selectedIDs.count)) {
                        onDone(selectedIDs.intersection(Set(allowedIDs)))
                    }
                    .inkProminent()
                    .disabled(selectedIDs.isEmpty || selectedIDs.count > 16)
                    .accessibilityIdentifier("knowledge.sources.done")
                }
            }
            .onChange(of: mode) { _, mode in
                switch mode {
                case .today, .week:
                    let calendar = Calendar.current
                    let dayFiltered = meetings.filter { meeting in
                        mode == .today
                            ? calendar.isDateInToday(meeting.createdAt)
                            : calendar.isDate(meeting.createdAt, equalTo: Date(), toGranularity: .weekOfYear)
                    }
                    selectedIDs = Set(WikiDefaultScope.select(
                        candidates: dayFiltered.map { (id: $0.id, createdAt: $0.createdAt) }, now: Date()))
                case .choose:
                    break
                }
            }
            .onChange(of: Set(allowedIDs)) { _, ids in selectedIDs.formIntersection(ids) }
        }
    }

    private func toggle(_ id: UUID) {
        mode = .choose
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else if selectedIDs.count < 16 { selectedIDs.insert(id) }
    }
}
