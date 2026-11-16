#if DEBUG
import SwiftData
import SwiftUI

/// Seeds the reviewed production layout for deterministic CI screenshots.
/// Requires all three synthetic UI-test arguments; it supplies only an initial
/// synthetic Knowledge selection, while Ask/Documents use the real screens.
struct KnowledgeNavigationPrototype: View {
    @Query(filter: #Predicate<Meeting> { $0.title == "Example portal review" }) private var meetings: [Meeting]

    var body: some View {
        KnowledgeRootNavigationView(initialTab: .knowledge, initialKnowledgeSourceIDs: Set(meetings.map(\.id)))
            .id(Set(meetings.map(\.id)))
    }
}
#endif
