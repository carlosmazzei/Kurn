import AgentHarness
import Foundation
import KurnCore
import SwiftData

/// SwiftData access stays on the main actor; retrieval sees only scoped value snapshots.
@MainActor
final class LibraryChatSourceReader: ChatSourceReader {
    typealias Search = @Sendable (String, [SemanticSearchService.Candidate], Int) async throws -> [SemanticSearchService.Hit]
    private let context: ModelContext
    private let scope: ChatSourceScope
    private let retrieve: Search

    init(context: ModelContext, scope: ChatSourceScope, search: @escaping Search = { query, candidates, limit in
        try await SemanticSearchService().hybridSearch(query: query, in: candidates, poolSize: limit)
    }) {
        self.context = context
        self.scope = scope
        self.retrieve = search
    }

    private func meetings() throws -> [Meeting] {
        SourceScopeResolver.resolve(scope, meetings: try context.fetch(FetchDescriptor<Meeting>()),
                                    tags: try context.fetch(FetchDescriptor<Tag>()),
                                    folders: try context.fetch(FetchDescriptor<Folder>())).meetings
    }

    private func meeting(_ id: UUID) throws -> Meeting? {
        try meetings().first { $0.id == id }
    }

    func authorizedSnapshot() throws -> AuthorizedChatSourceReader {
        try AuthorizedChatSourceReader(context: context, scope: scope, meetings: meetings(), search: retrieve)
    }

    func workload(allowedIDs: Set<UUID>) throws -> AgentWorkload {
        try ChatWorkloadEstimator.estimate(meetings: meetings().filter { allowedIDs.contains($0.id) }, scope: scope)
    }

    func listSources() async throws -> [ChatSource] {
        try meetings().map { meeting in
            let parts = scope.parts(for: meeting.id)
            return ChatSource(id: meeting.id, title: meeting.title, date: meeting.createdAt, duration: meeting.totalDuration,
                              tags: meeting.tags.map(\.name), folder: meeting.folder?.name,
                              availability: ChatSourceAvailability(summary: parts.contains(.summary) && meeting.latestSummary != nil,
                                                                   wiki: parts.contains(.wiki) && meeting.wikiArticle != nil,
                                                                   attachments: parts.contains(.attachments) && !meeting.attachments.isEmpty))
        }
    }

    func search(query: String, meetingIDs: Set<UUID>, limit: Int) async throws -> [ChatSourcePassage] {
        let selected = try meetings().filter { meetingIDs.contains($0.id) && scope.parts(for: $0.id).contains(.transcript) }
        guard !selected.isEmpty else { return [] }
        let ids = Set(selected.map(\.id))
        let candidates = selected.flatMap { $0.semanticChunks.map(\.searchCandidate) }
        return try await retrieve(query, candidates, min(max(limit, 1), 100))
            .filter { ids.contains($0.meetingID) }.map {
                ChatSourcePassage(meetingID: $0.meetingID, timestamp: $0.start, speaker: $0.speakerLabel, text: $0.text)
            }
    }

    func readTranscript(meetingID: UUID, offset: Int, limit: Int) async throws -> ChatTranscriptPage {
        guard scope.parts(for: meetingID).contains(.transcript), let meeting = try meeting(meetingID) else {
            return ChatTranscriptPage(passages: [], total: 0)
        }
        let passages = meeting.recordings.sorted { $0.recordedAt < $1.recordedAt }.flatMap { recording in
            (recording.transcript?.segments ?? []).map {
                ChatSourcePassage(meetingID: meetingID, timestamp: meeting.startOffset(of: recording) + $0.startTime,
                                  speaker: $0.speakerLabel, text: $0.text)
            }
        }
        return ChatTranscriptPage(passages: Array(passages.dropFirst(max(0, offset)).prefix(min(max(limit, 0), 50))),
                                  total: passages.count)
    }

    func readSummary(meetingID: UUID) async throws -> String? {
        guard scope.parts(for: meetingID).contains(.summary), let summary = try meeting(meetingID)?.latestSummary else { return nil }
        return SummaryService.markdownText(from: summary.sections)
    }

    func readWiki(meetingID: UUID) async throws -> String? {
        guard scope.parts(for: meetingID).contains(.wiki) else { return nil }
        return try meeting(meetingID)?.wikiArticle?.bodyMarkdown
    }

    func listAttachments(meetingID: UUID) async throws -> [ChatSourceAttachment] {
        guard scope.parts(for: meetingID).contains(.attachments) else { return [] }
        return try meeting(meetingID)?.sortedAttachments.map { ChatSourceAttachment(id: $0.id, name: $0.displayName) } ?? []
    }

    func readAttachment(meetingID: UUID, attachmentID: UUID) async throws -> String? {
        guard scope.parts(for: meetingID).contains(.attachments) else { return nil }
        return try meeting(meetingID)?.attachments.first { $0.id == attachmentID }?.extractedText
    }
}
