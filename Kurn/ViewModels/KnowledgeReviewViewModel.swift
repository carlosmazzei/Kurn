import Foundation
import Observation

enum KnowledgeReviewLoadState: Equatable {
    case idle, loading, unavailable
    case loaded(KnowledgeReviewRead)
}

@MainActor @Observable
final class KnowledgeReviewViewModel {
    typealias Reader = @MainActor () async throws -> KnowledgeReviewRead
    typealias Writer = @MainActor (KnowledgeReviewCommand, KnowledgeEntityMutationSnapshot) async throws -> Void
    private(set) var state: KnowledgeReviewLoadState = .idle
    private(set) var isWorking = false
    private(set) var decisionFailed = false
    @ObservationIgnored private var requestID = UUID()

    func invalidate() {
        requestID = UUID()
        state = .idle
        isWorking = false
        decisionFailed = false
    }

    func presentation(meetingIDs: Set<UUID>) -> KnowledgeReviewLoadState {
        let snapshot = state
        if case let .loaded(read) = snapshot, !Self.matches(read, meetingIDs: meetingIDs) { return .unavailable }
        return snapshot
    }

    func load(meetingIDs: Set<UUID>, isEnabled: () -> Bool, reader: Reader) async {
        guard !Task.isCancelled else { return }
        invalidate()
        guard isEnabled() else { return }
        state = .loading
        let request = requestID
        await publish(request: request, meetingIDs: meetingIDs, isEnabled: isEnabled, reader: reader)
    }

    private func publish(request: UUID, meetingIDs: Set<UUID>, isEnabled: () -> Bool, reader: Reader) async {
        do {
            let first = try await reader()
            let fresh = try await reader()
            guard requestID == request else { return }
            guard !Task.isCancelled, isEnabled(), first == fresh, Self.matches(fresh, meetingIDs: meetingIDs) else {
                state = .unavailable; return
            }
            state = .loaded(fresh)
        } catch {
            if requestID == request { state = isEnabled() && !Task.isCancelled ? .unavailable : .idle }
        }
    }

    func perform(_ command: KnowledgeReviewCommand, meetingIDs: Set<UUID>, isEnabled: () -> Bool,
                 reader: Reader, writer: Writer) async {
        guard !Task.isCancelled, isEnabled(), !isWorking, case let .loaded(read) = state,
              Self.matches(read, meetingIDs: meetingIDs), read.allowsMutation else { return }
        invalidate()
        let request = requestID
        state = .loading
        isWorking = true
        var failed = false
        do {
            let fresh = try await reader()
            guard isEnabled(), !Task.isCancelled, requestID == request else { throw CancellationError() }
            guard fresh == read else { throw KnowledgeEntityStoreError.staleSnapshot }
            try await writer(command, read.snapshot)
        } catch { failed = !(error is CancellationError) }
        guard requestID == request else { return }
        guard isEnabled(), !Task.isCancelled else { invalidate(); return }
        await publish(request: request, meetingIDs: meetingIDs, isEnabled: isEnabled, reader: reader)
        guard requestID == request else { return }
        isWorking = false
        if case .loaded = state { decisionFailed = failed }
    }

    private static func matches(_ read: KnowledgeReviewRead, meetingIDs: Set<UUID>) -> Bool {
        !meetingIDs.isEmpty && meetingIDs.count <= 16 && read.meetingIDs == meetingIDs
            && read.snapshot.sources.count == meetingIDs.count && read.snapshot.scope == "workspace" && read.snapshot.revision >= 0
    }
}
