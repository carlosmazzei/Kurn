//
//  QuestionRouter.swift
//  Kurn
//
//  Decides how the library-wide "Ask" should answer a question:
//
//  - **lookup** — a specific fact, quote, or moment ("what did Ana say about the
//    deadline"). Top-k retrieval over transcript passages answers these well and
//    cheaply.
//  - **synthesis** — spans, compares, counts, or finds themes across meetings
//    ("how did the budget evolve", "how many meetings discussed hiring"). Top-k
//    retrieval fails these by construction; they are answered over the condensed
//    per-meeting wiki articles instead.
//
//  A cheap multilingual keyword heuristic classifies the clear cases; genuinely
//  ambiguous ones fall back to a one-word LLM classification. On any failure the
//  default is synthesis: misrouting an aggregate to lookup reproduces the exact
//  shallow/uncounted answer the wiki path exists to fix, whereas the synthesis
//  path still answers a pinpoint question (just at higher cost).
//

import Foundation

enum QuestionRouter {
    enum Route { case lookup, synthesis }

    /// Markers that indicate synthesis/aggregation/comparison across meetings,
    /// lowercased, across the app's seven languages. Substring-matched, so stems
    /// (e.g. "reuni") catch inflections.
    private static let synthesisMarkers: [String] = [
        // English
        "how many", "how much", "all meetings", "every meeting", "each meeting",
        "across", "compare", "comparison", "trend", "theme", "themes", "overall",
        "summarize", "summarise", "in total", "combined", "recurring", "list all",
        "list every", "most common",
        // Portuguese
        "quantas", "quantos", "todas as reuni", "todas reuni", "cada reuni",
        "compare", "comparar", "compara", "tendência", "tema", "temas", "no total",
        "resuma", "resumir", "ao longo", "recorrente", "liste todas", "liste todos",
        "em todas",
        // Spanish
        "cuántas", "cuántos", "todas las reuni", "cada reuni", "compara", "comparar",
        "tendencia", "tema", "temas", "en total", "resume", "resumir", "a lo largo",
        "recurrente", "en todas",
        // French
        "combien", "toutes les réuni", "chaque réuni", "compare", "comparer",
        "tendance", "thème", "thèmes", "au total", "résume", "résumer", "récurrent",
        "dans toutes",
        // Italian
        "quante", "quanti", "tutte le riuni", "ogni riuni", "confronta", "confrontare",
        "tendenza", "tema", "temi", "in totale", "riassumi", "ricorrente",
        // German
        "wie viele", "wie viel", "alle meetings", "jedes meeting", "vergleiche",
        "vergleichen", "trend", "thema", "themen", "insgesamt", "zusammenfassen",
        "wiederkehrend",
        // Simplified Chinese
        "多少", "所有会议", "每场会议", "每个会议", "比较", "趋势", "主题", "总共",
        "总结", "归纳", "反复"
    ]

    /// The subset of synthesis markers that imply a library-wide scope ("all/every
    /// meeting", counts, totals), so the synthesis path considers every article
    /// rather than only retrieval-ranked ones.
    private static let globalAggregateMarkers: [String] = [
        "how many", "how much", "all meetings", "every meeting", "each meeting",
        "across all", "in total", "list all", "list every", "combined",
        "quantas", "quantos", "todas as reuni", "todas reuni", "cada reuni",
        "no total", "liste todas", "liste todos", "em todas",
        "cuántas", "cuántos", "todas las reuni", "cada reuni", "en total", "en todas",
        "combien", "toutes les réuni", "chaque réuni", "au total", "dans toutes",
        "quante", "quanti", "tutte le riuni", "ogni riuni", "in totale",
        "wie viele", "wie viel", "alle meetings", "jedes meeting", "insgesamt",
        "多少", "所有会议", "每场会议", "每个会议", "总共"
    ]

    /// Markers that indicate a pinpoint lookup within one meeting.
    private static let lookupMarkers: [String] = [
        "who said", "what did", "when did", "quote", "at what time", "who mentioned",
        "quem disse", "o que disse", "cite", "em que momento", "quem mencionou",
        "quién dijo", "qué dijo", "cita", "en qué momento",
        "qui a dit", "qu'a dit", "à quel moment",
        "chi ha detto", "cosa ha detto", "cita", "in che momento",
        "wer hat gesagt", "zu welchem zeitpunkt", "zitat",
        "谁说", "说了什么", "什么时候", "引用", "在哪个时刻"
    ]

    /// Classify from keywords alone, or `nil` when the signal is mixed/absent.
    static func heuristic(_ question: String) -> Route? {
        let q = question.lowercased()
        let synthesis = synthesisMarkers.contains { q.contains($0) }
        let lookup = lookupMarkers.contains { q.contains($0) }
        if synthesis && !lookup { return .synthesis }
        if lookup && !synthesis { return .lookup }
        return nil
    }

    /// Whether the question asks about the whole library (counts, "all/every"),
    /// so the synthesis path should include every available article.
    static func isGlobalAggregate(_ question: String) -> Bool {
        let q = question.lowercased()
        return globalAggregateMarkers.contains { q.contains($0) }
    }

    /// Heuristic first; a one-word LLM classification breaks genuine ties. Any
    /// failure defaults to synthesis.
    static func classify(_ question: String, llm: LLMProvider) async -> Route {
        if let route = heuristic(question) { return route }
        let system = """
        Classify the user's question as either LOOKUP or SYNTHESIS. \
        LOOKUP asks about a specific fact, moment, or quote (usually in one \
        meeting). SYNTHESIS asks to summarize, compare, count, or find themes \
        across multiple meetings. Reply with ONLY one word: LOOKUP or SYNTHESIS.
        """
        if let reply = try? await llm.chat(
            systemPrompt: system, messages: [ChatMessage(role: .user, content: question)]
        ) {
            let upper = reply.uppercased()
            if upper.contains("LOOKUP") && !upper.contains("SYNTHESIS") { return .lookup }
            if upper.contains("SYNTHESIS") { return .synthesis }
        }
        return .synthesis
    }
}
