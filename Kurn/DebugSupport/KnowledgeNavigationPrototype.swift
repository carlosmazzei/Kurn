#if DEBUG
import SwiftData
import SwiftUI

/// The production meetings screen with Knowledge on, opened on its Knowledge
/// sheet for deterministic CI screenshots. Requires all three synthetic
/// UI-test arguments; it supplies only the initial synthetic Knowledge
/// selection, while Ask and Documents use the real screens.
struct KnowledgeNavigationPrototype: View {
    @Query(filter: #Predicate<Meeting> { $0.title == "Example portal review" }) private var meetings: [Meeting]
    @State private var selection: LibrarySelection = .allMeetings

    var body: some View {
        NavigationStack {
            MeetingsListView(selection: $selection, initialKnowledgeSourceIDs: Set(meetings.map(\.id)))
        }
    }
}
#endif
