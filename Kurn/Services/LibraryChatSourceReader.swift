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

    func listSources() async throws -> [ChatSource] {
        try meetings().map {
            ChatSource(id: $0.id, title: $0.title, date: $0.createdAt, duration: $0.totalDuration,
                       tags: $0.tags.map(\.name), folder: $0.folder?.name,
                       availability: ChatSourceAvailability(summary: $0.latestSummary != nil,
                                                            wiki: scope.includeWikis && $0.wikiArticle != nil,
                                                            attachments: !$0.attachments.isEmpty))
        }
    }

    func search(query: String, meetingIDs: Set<UUID>, limit: Int) async throws -> [ChatSourcePassage] {
        let selected = try meetings().filter { meetingIDs.contains($0.id) }
        let ids = Set(selected.map(\.id))
        let candidates = selected.flatMap { $0.semanticChunks.map(\.searchCandidate) }
        return try await retrieve(query, candidates, min(max(limit, 1), 100))
            .filter { ids.contains($0.meetingID) }.map {
                ChatSourcePassage(meetingID: $0.meetingID, timestamp: $0.start, speaker: $0.speakerLabel, text: $0.text)
            }
    }

    func readTranscript(meetingID: UUID, offset: Int, limit: Int) async throws -> ChatTranscriptPage {
        guard let meeting = try meeting(meetingID) else { return ChatTranscriptPage(passages: [], total: 0) }
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
        guard let summary = try meeting(meetingID)?.latestSummary else { return nil }
        return SummaryService.markdownText(from: summary.sections)
    }

    func readWiki(meetingID: UUID) async throws -> String? {
        guard scope.includeWikis else { return nil }
        return try meeting(meetingID)?.wikiArticle?.bodyMarkdown
    }

    func listAttachments(meetingID: UUID) async throws -> [ChatSourceAttachment] {
        try meeting(meetingID)?.sortedAttachments.map { ChatSourceAttachment(id: $0.id, name: $0.displayName) } ?? []
    }

    func readAttachment(meetingID: UUID, attachmentID: UUID) async throws -> String? {
        try meeting(meetingID)?.attachments.first { $0.id == attachmentID }?.extractedText
    }
}
