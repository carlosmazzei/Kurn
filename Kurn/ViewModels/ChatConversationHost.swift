import Foundation
import Observation

/// The host owner of chat conversations (NH05 host activation). A conversation used to be the
/// `@State` of the view showing it, and dismissing the view cancelled its run — so a long
/// answer, or a document the agent was writing, died with a sheet swipe. The host retains one
/// conversation per scope (a meeting, or the library-wide Ask) for the life of the store, so a
/// run continues when its view goes away and reopening the scope shows it still running or
/// finished from where it was saved.
///
/// Retention is bounded: at most `capacity` conversations are kept, evicting the least recently
/// opened idle one whenever a conversation is opened; a running conversation is never evicted,
/// so the bound can be exceeded only until the next open after those runs settle. Nothing here is observable: the
/// conversations are, and handing one out must not invalidate the view asking for it.
@MainActor
@Observable
final class ChatConversationHost {
    enum Scope: Hashable { case library, meeting(UUID) }

    let capacity: Int
    private let makeConversation: @MainActor () -> MeetingChatViewModel
    @ObservationIgnored private var conversations: [Scope: MeetingChatViewModel] = [:]
    @ObservationIgnored private var lastOpened: [Scope: UInt64] = [:]
    @ObservationIgnored private var clock: UInt64 = 0

    init(capacity: Int = 4, makeConversation: @escaping @MainActor () -> MeetingChatViewModel = { MeetingChatViewModel() }) {
        self.capacity = max(1, capacity)
        self.makeConversation = makeConversation
    }

    /// The retained conversation for `meetingID` (`nil` is the library-wide Ask), created on
    /// first use.
    func conversation(for meetingID: UUID?) -> MeetingChatViewModel {
        let scope: Scope = meetingID.map { .meeting($0) } ?? .library
        clock += 1
        lastOpened[scope] = clock
        let conversation = conversations[scope] ?? makeConversation()
        conversations[scope] = conversation
        // Every access re-applies the bound: conversations that were running when they would have
        // been evicted have settled since, and nothing else tells the host they went idle.
        evictIdle(keeping: scope)
        return conversation
    }

    /// Scopes currently retained, for tests and diagnostics.
    var retainedScopes: Set<Scope> { Set(conversations.keys) }

    /// Cancels every run, waits until each has settled, then forgets every conversation. Used
    /// before the library is erased: a retained conversation holds models that erasure deletes,
    /// and a run must not write into a session that no longer exists.
    func closeAll() async {
        let open = Array(conversations.values)
        for conversation in open { conversation.cancel() }
        for conversation in open { await conversation.waitUntilSettled() }
        conversations.removeAll()
        lastOpened.removeAll()
    }

    private func evictIdle(keeping current: Scope) {
        let idle = conversations
            .filter { $0.key != current && !$0.value.isResponding }
            .map(\.key)
            .sorted { (lastOpened[$0] ?? 0) < (lastOpened[$1] ?? 0) }
        for scope in idle where conversations.count > capacity {
            conversations[scope] = nil
            lastOpened[scope] = nil
        }
    }
}
