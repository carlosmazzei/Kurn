import Foundation
import KurnCore
import Observation

enum KnowledgeSearchState: Equatable {
    case idle, loading, unavailable, limited
    case loaded([KnowledgeSearchDocument])
}

@MainActor @Observable
final class KnowledgeSearchViewModel {
    typealias Reader = @MainActor @Sendable () async throws -> KnowledgeBrowserRead
    typealias Authorization = @Sendable () async throws -> Bool
    typealias Searcher = @Sendable (String, KnowledgeBrowserRead, Bool, Authorization) async throws -> [KnowledgeSearchDocument]

    private(set) var state: KnowledgeSearchState = .idle
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var meetingIDs: Set<UUID> = []

    func invalidate() { requestID = UUID(); state = .idle }

    func presentation(query: String, meetingIDs: Set<UUID>) -> KnowledgeSearchState {
        self.query == query && self.meetingIDs == meetingIDs ? state : .idle
    }

    func search(query: String, meetingIDs: Set<UUID>, useSemantic: Bool,
                isEnabled: @escaping @MainActor @Sendable () -> Bool, reader: @escaping Reader,
                searcher: Searcher = { query, read, dense, authorize in
                    try await KnowledgeSearchService().search(query: query, read: read, useSemantic: dense, authorizeEmbedding: authorize)
                }) async {
        invalidate()
        self.query = query
        self.meetingIDs = meetingIDs
        let request = requestID
        guard isEnabled(), !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Task.isCancelled else { return }
        guard query.count <= KnowledgeSearchIndex.queryLimit, query.utf8.count <= 1_024 else { state = .limited; return }
        state = .loading
        do {
            let before = try await reader()
            guard requestID == request else { return }
            guard before.meetingIDs == meetingIDs, before.selectedEvidence == nil, isEnabled(), !Task.isCancelled else {
                state = .unavailable; return
            }
            let authorize: Authorization = { [weak self] in
                guard let self else { return false }
                let fresh = try await reader()
                return await MainActor.run {
                    self.requestID == request && isEnabled() && !Task.isCancelled && fresh == before && fresh.allowsEmbedding
                }
            }
            let hits = try await searcher(query, before, useSemantic && before.allowsEmbedding, authorize)
            guard requestID == request else { return }
            try Task.checkCancellation()
            let after = try await reader()
            guard requestID == request else { return }
            guard after == before else {
                state = .unavailable; return
            }
            let valid = try await KnowledgeSearchService.validates(hits, in: after)
            guard requestID == request else { return }
            guard isEnabled(), !Task.isCancelled else { invalidate(); return }
            guard valid else { state = .unavailable; return }
            state = .loaded(hits)
        } catch is CancellationError {
            if requestID == request { invalidate() }
        } catch let error as KnowledgeSearchError {
            if requestID == request {
                state = error == .invalidQuery || error == .indexLimit ? .limited : .unavailable
            }
        } catch {
            if requestID == request { state = isEnabled() && !Task.isCancelled ? .unavailable : .idle }
        }
    }
}
