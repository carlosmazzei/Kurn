import Foundation
import Observation

@MainActor
@Observable
final class MeetingKnowledgeViewModel {
    private(set) var state: MeetingKnowledgeState = .idle
    @ObservationIgnored private var requestID = UUID()

    func invalidate() {
        requestID = UUID()
        state = .idle
    }

    func load(meetingID: UUID, isEnabled: @MainActor () -> Bool,
              reader: @MainActor () async throws -> MeetingKnowledgeRead) async {
        let request = UUID()
        requestID = request
        guard isEnabled(), !Task.isCancelled else { state = .idle; return }
        state = .loading // No old names/counts while a fresh read is pending.
        do {
            let result = try await reader()
            guard requestID == request else { return }
            guard !Task.isCancelled, isEnabled() else { invalidate(); return }
            guard result.meetingID == meetingID else { state = .unavailable; return }
            state = .loaded(result)
        } catch is CancellationError {
            if requestID == request { invalidate() }
        } catch {
            if requestID == request { state = isEnabled() && !Task.isCancelled ? .unavailable : .idle }
        }
    }

    func presentation(for meetingID: UUID) -> MeetingKnowledgeState {
        if case let .loaded(read) = state, read.meetingID != meetingID { return .idle }
        return state
    }

    func header(for meetingID: UUID) -> String {
        switch presentation(for: meetingID) {
        case let .loaded(read): read.summary
        case .idle, .loading: NSLocalizedString("detail.knowledge.loading", comment: "Loading contributions")
        case .unavailable: NSLocalizedString("detail.knowledge.unavailable", comment: "Knowledge unavailable")
        }
    }
}
