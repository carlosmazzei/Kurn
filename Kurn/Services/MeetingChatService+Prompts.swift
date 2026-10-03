//
//  MeetingChatService+Prompts.swift
//  Kurn
//
//  The prompts `MeetingChatService` sends: the full-transcript grounding,
//  the per-scope system prompts, and the retrieval prompts that group
//  excerpts by meeting. Split out of `MeetingChatService.swift`, which holds
//  the retrieval and answer pipeline, to keep that file under SwiftLint's
//  file-length limit.
//

import Foundation
import KurnCore

extension MeetingChatService {

    /// Grounding for the full-transcript path.
    static let fullContextSystemPrompt = """
    You are an assistant that answers questions about a meeting using the \
    transcript provided in the user message. Follow these rules:
    - Base your answer on the transcript. Do not invent facts or use outside \
    knowledge about the participants or topic.
    - If the transcript does not contain the answer, say so plainly.
    - Cite the moments you rely on using their [mm:ss] timestamps from the \
    transcript.
    - Reply in the SAME LANGUAGE as the transcript.
    - Be concise and direct; quote a speaker verbatim only when it adds clarity.
    """

    static func fullContextPrompt(question: String, transcript: String) -> String {
        """
        Question: \(question)

        Meeting transcript (each line is "[mm:ss] Speaker: text"):
        \(transcript)
        """
    }

    /// Grounding for the retrieval path: answer only from the excerpts.
    static let systemPrompt = """
    You are an assistant that answers questions about a meeting using ONLY the \
    transcript excerpts provided in each user message. Follow these rules:
    - Base your answer strictly on the excerpts. Do not invent facts or use \
    outside knowledge about the participants or topic.
    - If the excerpts do not contain the answer, say so plainly instead of \
    guessing.
    - Cite the moments you rely on using their [mm:ss] timestamps from the \
    excerpts.
    - Reply in the SAME LANGUAGE as the transcript excerpts.
    - Be concise and direct; quote a speaker verbatim only when it adds clarity.
    """

    /// Grounding for the library-wide retrieval path: excerpts span several
    /// meetings, each headed by its title and date, so the model must attribute
    /// and compare across meetings.
    static let librarySystemPrompt = """
    You are an assistant that answers questions across a personal library of \
    meetings, using ONLY the meeting overviews and transcript excerpts provided \
    in each user message. Follow these rules:
    - Each excerpt is grouped under the meeting it came from, headed by \
    "### <meeting title> — <date>". Attribute every claim to a meeting by \
    naming its title (and date when useful).
    - When a question spans meetings, compare and connect what the different \
    meetings say.
    - Base your answer strictly on the provided overviews and excerpts. Do not \
    invent facts or use outside knowledge about the participants or topics.
    - If the material does not contain the answer, say so plainly instead of \
    guessing.
    - Cite the moments you rely on using their [mm:ss] timestamps.
    - Reply in the SAME LANGUAGE as the excerpts.
    - Be concise and direct; quote a speaker verbatim only when it adds clarity.
    """

    /// The system prompt for a retrieval scope.
    static func systemPrompt(for scope: Scope) -> String {
        switch scope {
        case .singleMeeting: return systemPrompt
        case .library: return librarySystemPrompt
        }
    }

    /// The per-turn user message for the retrieval path: the question plus the
    /// retrieved passages. Single-meeting scope renders plain `[mm:ss] Speaker:
    /// text` lines; library scope groups them by meeting (with title/date headers
    /// and any per-meeting overviews) so the model can attribute across meetings.
    static func userPrompt(
        question: String,
        hits: [SemanticSearchService.Hit],
        scope: Scope,
        summaries: [UUID: String]
    ) -> String {
        guard !hits.isEmpty else { return emptyPrompt(question: question, scope: scope) }
        switch scope {
        case .singleMeeting:
            let excerpts = hits.map(\.promptLine).joined(separator: "\n")
            return """
            Question: \(question)

            Relevant excerpts from the meeting transcript:
            \(excerpts)
            """
        case .library:
            return libraryUserPrompt(question: question, hits: hits, summaries: summaries)
        }
    }

    /// The message when nothing matched, phrased for the scope.
    private static func emptyPrompt(question: String, scope: Scope) -> String {
        let closing = scope == .library
            ? "couldn't find anything about it across their meetings."
            : "couldn't find anything about it in the meeting."
        return """
        Question: \(question)

        No transcript excerpts matched this question. Tell the user you \
        \(closing)
        """
    }

    /// Group hits by meeting, ordered by their best-ranked appearance.
    /// Not `private`: reused by the combined answer in `MeetingChatSynthesis.swift`.
    static func groupByMeeting(
        _ hits: [SemanticSearchService.Hit]
    ) -> [(id: UUID, hits: [SemanticSearchService.Hit])] {
        var order: [UUID] = []
        var grouped: [UUID: [SemanticSearchService.Hit]] = [:]
        for hit in hits {
            if grouped[hit.meetingID] == nil { order.append(hit.meetingID) }
            grouped[hit.meetingID, default: []].append(hit)
        }
        return order.map { (id: $0, hits: grouped[$0] ?? []) }
    }

    /// Excerpts grouped under their meeting's `### <title> — <date>` header.
    /// `chronological` orders the groups oldest-first (what the synthesis path
    /// wants, so the excerpts line up with the wiki articles); otherwise groups
    /// keep retrieval order, best-ranked meeting first.
    /// Not `private`: reused by the combined answer in `MeetingChatSynthesis.swift`.
    static func renderGroupedExcerpts(
        _ hits: [SemanticSearchService.Hit],
        chronological: Bool = false
    ) -> String {
        var groups = groupByMeeting(hits)
        if chronological {
            groups.sort {
                ($0.hits.first?.meetingDate ?? .distantPast) < ($1.hits.first?.meetingDate ?? .distantPast)
            }
        }
        return groups.map { group -> String in
            let head = group.hits.first.map(meetingHeader) ?? "###"
            let lines = group.hits.map(\.promptLine).joined(separator: "\n")
            return "\(head)\n\(lines)"
        }.joined(separator: "\n\n")
    }

    /// A `### <title> — <date>` header for the meeting a hit belongs to.
    /// Not `private`: reused by the combined answer in `MeetingChatSynthesis.swift`.
    static func meetingHeader(_ hit: SemanticSearchService.Hit) -> String {
        let title = hit.meetingTitle.isEmpty
            ? NSLocalizedString("chat.untitled_meeting", comment: "Fallback name for a meeting without a title")
            : hit.meetingTitle
        guard hit.meetingDate != .distantPast else { return "### \(title)" }
        return "### \(title) — \(hit.meetingDate.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Library-wide user message: optional per-meeting overviews, then excerpts
    /// grouped and attributed by meeting.
    private static func libraryUserPrompt(
        question: String,
        hits: [SemanticSearchService.Hit],
        summaries: [UUID: String]
    ) -> String {
        let groups = groupByMeeting(hits)
        let excerpts = renderGroupedExcerpts(hits)

        let overviews = groups.compactMap { group -> String? in
            guard let summary = summaries[group.id], !summary.isEmpty,
                  let head = group.hits.first.map(meetingHeader) else { return nil }
            return "\(head)\n\(summary)"
        }.joined(separator: "\n\n")

        var prompt = "Question: \(question)\n"
        if !overviews.isEmpty {
            prompt += "\nMeeting overviews (condensed summaries of the meetings the excerpts below come from):\n\(overviews)\n"
        }
        prompt += "\nRelevant excerpts, grouped by meeting (each headed by its title and date):\n\(excerpts)"
        return prompt
    }
}
