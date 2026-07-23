//
//  LibraryQuestion.swift
//  Kurn
//
//  A tiny bit of analysis for the library-wide "Ask": whether a question is a
//  *global aggregate* — a count or an "all/every meeting" question that must be
//  answered exhaustively over every meeting, not just the retrieval-ranked ones
//  ("how many meetings discussed hiring", "list every action item").
//
//  This is deliberately NOT a lookup-vs-synthesis router: the chat always gives
//  the model both the retrieved verbatim excerpts and the condensed wiki
//  articles, so it can quote precisely and reason across meetings in one pass.
//  The only thing that needs deciding up front is whether to widen the article
//  set to the whole library so a count can't miss a meeting retrieval didn't
//  surface — a cheap multilingual keyword check, no LLM call.
//

import Foundation

enum LibraryQuestion {
    /// Markers implying a library-wide, exhaustive scope (counts, totals,
    /// "all/every meeting"), lowercased across the app's seven languages.
    /// Substring-matched so stems catch inflections.
    private static let globalAggregateMarkers: [String] = [
        // English
        "how many", "how much", "all meetings", "every meeting", "each meeting",
        "across all", "in total", "list all", "list every", "combined",
        // Portuguese
        "quantas", "quantos", "todas as reuni", "todas reuni", "cada reuni",
        "no total", "liste todas", "liste todos", "em todas",
        // Spanish
        "cuántas", "cuántos", "todas las reuni", "cada reuni", "en total", "en todas",
        // French
        "combien", "toutes les réuni", "chaque réuni", "au total", "dans toutes",
        // Italian
        "quante", "quanti", "tutte le riuni", "ogni riuni", "in totale",
        // German
        "wie viele", "wie viel", "alle meetings", "jedes meeting", "insgesamt",
        // Simplified Chinese
        "多少", "所有会议", "每场会议", "每个会议", "总共"
    ]

    /// Whether the question asks about the whole library (counts, "all/every"),
    /// so the synthesis should include every available article rather than only
    /// the retrieval-ranked ones.
    static func isGlobalAggregate(_ question: String) -> Bool {
        let q = question.lowercased()
        return globalAggregateMarkers.contains { q.contains($0) }
    }
}
