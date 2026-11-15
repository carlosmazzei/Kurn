//
//  ChatSessionSearch.swift
//  Kurn
//
//  Search over a chat's saved conversations: each query word must occur in the conversation's
//  title or in what it shows (the branch each conversation is open on), ignoring case and
//  accents. A match in the text comes with a short excerpt around it for the history list.
//

import Foundation

enum ChatSessionSearch {
    struct Match: Equatable {
        /// Text around the first match in the conversation's turns; nil when only the title matched.
        let excerpt: String?
    }

    static let excerptRadius = 40
    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// The conversations that match `query`, in their order, each with its match. An empty query
    /// keeps every conversation, with no excerpt.
    static func results(_ sessions: [ChatSession], query: String) -> [(session: ChatSession, match: Match)] {
        sessions.compactMap { session in
            match(title: session.title, texts: session.turns.map(\.text), query: query).map { (session, $0) }
        }
    }

    static func match(title: String, texts: [String], query: String) -> Match? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Match(excerpt: nil) }
        let haystacks = [title] + texts
        guard words.allSatisfy({ word in haystacks.contains { $0.range(of: word, options: options) != nil } }) else { return nil }
        for text in texts {
            for word in words {
                if let range = text.range(of: word, options: options) { return Match(excerpt: excerpt(text, around: range)) }
            }
        }
        return Match(excerpt: nil)
    }

    /// Up to `excerptRadius` characters each side of `range`, on one line, with an ellipsis where cut.
    static func excerpt(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -excerptRadius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: excerptRadius, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}
