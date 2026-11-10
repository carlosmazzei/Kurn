import AgentHarness
import CryptoKit
import Foundation
import KurnCore
import SwiftData

/// A task sees the selected IDs, parts and exact source revision captured at acceptance.
/// Later edits cannot expand or change that context. Deleted sources fail explicitly.
@MainActor
final class AuthorizedChatSourceReader: ChatSourceReader {
    private struct Source: Codable {
        let metadata: ChatSource
        let parts: [ChatSourcePart]
        let passages: [ChatSourcePassage]
        let summary: String?
        let wiki: String?
        let attachments: [ChatSourceAttachment]
        let attachmentText: [String: String]
        let candidates: [SemanticSearchService.Candidate]
    }
    private let context: ModelContext
    private let sources: [UUID: Source]
    private let retrieve: LibraryChatSourceReader.Search
    let revisions: [UUID: String]
    let workload: AgentWorkload

    init(context: ModelContext, scope: ChatSourceScope, meetings: [Meeting], search: @escaping LibraryChatSourceReader.Search) throws {
        self.context = context; retrieve = search
        workload = ChatWorkloadEstimator.estimate(meetings: meetings, scope: scope)
        var sources: [UUID: Source] = [:]
        var revisions: [UUID: String] = [:]
        for meeting in meetings {
            let parts = scope.parts(for: meeting.id)
            let summary = parts.contains(.summary) ? meeting.latestSummary.map { SummaryService.markdownText(from: $0.sections) } : nil
            let wiki = parts.contains(.wiki) ? meeting.wikiArticle?.bodyMarkdown : nil
            let attachments = parts.contains(.attachments) ? meeting.sortedAttachments : []
            let passages = parts.contains(.transcript) ? meeting.recordings.sorted { $0.recordedAt < $1.recordedAt }.flatMap { recording in
                (recording.transcript?.segments ?? []).map {
                    ChatSourcePassage(meetingID: meeting.id, timestamp: meeting.startOffset(of: recording) + $0.startTime,
                        speaker: $0.speakerLabel, text: $0.text)
                }
            } : []
            let source = Source(metadata: ChatSource(id: meeting.id, title: meeting.title, date: meeting.createdAt, duration: meeting.totalDuration,
                tags: meeting.tags.map(\.name).sorted(), folder: meeting.folder?.name,
                availability: ChatSourceAvailability(summary: summary != nil, wiki: wiki != nil, attachments: !attachments.isEmpty)),
                parts: ChatSourcePart.allCases.filter { parts.contains($0) }, passages: passages, summary: summary, wiki: wiki,
                attachments: attachments.map { ChatSourceAttachment(id: $0.id, name: $0.displayName) },
                attachmentText: Dictionary(uniqueKeysWithValues: attachments.compactMap { attachment in attachment.extractedText.map { (attachment.id.uuidString, $0) } }),
                candidates: parts.contains(.transcript) ? meeting.semanticChunks.map(\.searchCandidate).sorted { $0.chunkID.uuidString < $1.chunkID.uuidString } : [])
            sources[meeting.id] = source
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            revisions[meeting.id] = SHA256.hash(data: try encoder.encode(source)).map { String(format: "%02x", $0) }.joined()
        }
        self.sources = sources; self.revisions = revisions
    }

    private func require(_ id: UUID) throws -> Source {
        guard let source = sources[id] else { throw ChatDocumentError("Source outside the authorization snapshot.") }
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })
        guard try context.fetch(descriptor).first != nil else { throw ChatDocumentError("Authorized source was deleted.") }
        return source
    }

    func listSources() async throws -> [ChatSource] {
        try sources.keys.sorted { $0.uuidString < $1.uuidString }.map { try require($0).metadata }
    }

    func search(query: String, meetingIDs: Set<UUID>, limit: Int) async throws -> [ChatSourcePassage] {
        let selected = try meetingIDs.map { try require($0) }.filter { $0.parts.contains(.transcript) }
        let hits = try await retrieve(query, selected.flatMap(\.candidates), min(max(limit, 1), 100))
        // Search may suspend; deletion while ranking cannot return stale authorized content.
        for id in meetingIDs { _ = try require(id) }
        return hits.filter { meetingIDs.contains($0.meetingID) }.map {
            ChatSourcePassage(meetingID: $0.meetingID, timestamp: $0.start, speaker: $0.speakerLabel, text: $0.text)
        }
    }

    func readTranscript(meetingID: UUID, offset: Int, limit: Int) async throws -> ChatTranscriptPage {
        let source = try require(meetingID)
        let passages = source.parts.contains(.transcript) ? source.passages : []
        return ChatTranscriptPage(passages: Array(passages.dropFirst(max(0, offset)).prefix(min(max(limit, 0), 50))), total: passages.count)
    }
    func readSummary(meetingID: UUID) async throws -> String? { try require(meetingID).summary }
    func readWiki(meetingID: UUID) async throws -> String? { try require(meetingID).wiki }
    func listAttachments(meetingID: UUID) async throws -> [ChatSourceAttachment] { try require(meetingID).attachments }
    func readAttachment(meetingID: UUID, attachmentID: UUID) async throws -> String? {
        let source = try require(meetingID)
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })
        guard try context.fetch(descriptor).first?.attachments.contains(where: { $0.id == attachmentID }) == true else {
            throw ChatDocumentError("Authorized attachment was deleted.")
        }
        return source.attachmentText[attachmentID.uuidString]
    }
}
