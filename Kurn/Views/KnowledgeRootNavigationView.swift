import SwiftUI

/// The reviewed four-destination layout, enabled with knowledgeEnabled. Each
/// destination owns its stack; tab changes retain the meetings controls and
/// the app-owned library conversation rather than presenting another chat.
struct KnowledgeRootNavigationView: View {
    @State private var tab: AppRootDestination
    @State private var selection: LibrarySelection = .allMeetings
    let initialKnowledgeSourceIDs: Set<UUID>

    init(initialTab: AppRootDestination = .meetings, initialKnowledgeSourceIDs: Set<UUID> = []) {
        _tab = State(initialValue: initialTab)
        self.initialKnowledgeSourceIDs = initialKnowledgeSourceIDs
    }

    var body: some View {
        TabView(selection: $tab) {
            ZStack {
                NavigationStack { MeetingsListView(selection: $selection, usesRootTabs: true) }
            }
            .hostsRecordingMiniBar()
            .tabItem { Label(AppRootDestination.meetings.title, systemImage: AppRootDestination.meetings.systemImage) }
            .tag(AppRootDestination.meetings)

            KnowledgeLibraryDestination(initialMeetingIDs: initialKnowledgeSourceIDs)
                .hostsRecordingMiniBar()
                .tabItem { Label(AppRootDestination.knowledge.title, systemImage: AppRootDestination.knowledge.systemImage) }
                .tag(AppRootDestination.knowledge)

            ZStack {
                NavigationStack {
                    MeetingChatView(meeting: nil)
                        .navigationTitle(NSLocalizedString("chat.ask.title", comment: "Ask across meetings"))
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .hostsRecordingMiniBar()
            .tabItem { Label(AppRootDestination.ask.title, systemImage: AppRootDestination.ask.systemImage) }
            .tag(AppRootDestination.ask)

            ZStack { NavigationStack { DocumentsListView() } }
                .hostsRecordingMiniBar()
                .tabItem { Label(AppRootDestination.documents.title, systemImage: AppRootDestination.documents.systemImage) }
                .tag(AppRootDestination.documents)
        }
    }
}
