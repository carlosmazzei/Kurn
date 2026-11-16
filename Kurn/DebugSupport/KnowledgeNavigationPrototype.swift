#if DEBUG
import SwiftData
import SwiftUI

/// K0.5 review artifact only. Requires all three synthetic UI-test arguments in
/// ContentView; no production global navigation or release flag activates it.
struct KnowledgeNavigationPrototype: View {
    @Query(filter: #Predicate<Meeting> { $0.title == "Example portal review" }) private var meetings: [Meeting]
    @State private var selection: LibrarySelection = .allMeetings
    @State private var tab = 1

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { MeetingsListView(selection: $selection) }
                .tabItem { Label(KnowledgeBrowserCopy.text("meetings"), systemImage: "mic") }.tag(0)
            KnowledgeBrowserView(meetingIDs: Set(meetings.map(\.id)), showsDone: false)
                .tabItem { Label(KnowledgeBrowserCopy.text("title"), systemImage: "book.pages") }.tag(1)
            NavigationStack {
                ContentUnavailableView(KnowledgeBrowserCopy.text("ask"), systemImage: "bubble.left.and.bubble.right",
                    description: Text(KnowledgeBrowserCopy.text("ask_prototype")))
                    .navigationTitle(KnowledgeBrowserCopy.text("ask"))
            }
            .tabItem { Label(KnowledgeBrowserCopy.text("ask"), systemImage: "bubble.left.and.bubble.right") }.tag(2)
        }
    }
}
#endif
