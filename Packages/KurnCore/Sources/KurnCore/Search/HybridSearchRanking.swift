import Foundation

/// Shared by transcript retrieval and typed knowledge documents. Ranking is
/// local, deterministic, and independent of providers and persistence.
public enum HybridSearchRanking {
    public static func bm25Order(query: String, texts: [String]) -> [Int] {
        let queryTerms = Set(tokenize(query)).sorted()
        guard !queryTerms.isEmpty else { return [] }

        let docs = texts.map(tokenize)
        let count = docs.count
        let avgdl = Double(docs.reduce(0) { $0 + $1.count }) / Double(max(count, 1))

        var docFreq: [String: Int] = [:]
        for doc in docs {
            let present = Set(doc)
            for term in queryTerms where present.contains(term) { docFreq[term, default: 0] += 1 }
        }

        let k1 = 1.5, bParam = 0.75
        var scored: [(index: Int, score: Double)] = []
        for (index, doc) in docs.enumerated() where !doc.isEmpty {
            var termFreq: [String: Int] = [:]
            for term in doc { termFreq[term, default: 0] += 1 }
            let docLen = Double(doc.count)
            var score = 0.0
            for term in queryTerms {
                guard let freq = termFreq[term], freq > 0, let df = docFreq[term], df > 0 else { continue }
                let idf = log(1 + (Double(count) - Double(df) + 0.5) / (Double(df) + 0.5))
                let tfPart = (Double(freq) * (k1 + 1)) / (Double(freq) + k1 * (1 - bParam + bParam * docLen / avgdl))
                score += idf * tfPart
            }
            if score > 0 { scored.append((index, score)) }
        }
        return scored.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }.map(\.index)
    }

    public static func tokenize(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
    }

    public static func reciprocalRankFusion(_ rankings: [[Int]], k: Int = 60) -> [(index: Int, score: Double)] {
        guard k >= 0 else { return [] }
        var scores: [Int: Double] = [:]
        for ranking in rankings {
            var seen: Set<Int> = []
            for (rank, index) in ranking.enumerated() where index >= 0 && seen.insert(index).inserted {
                scores[index, default: 0] += 1.0 / Double(k + rank + 1)
            }
        }
        return scores.map { (index: $0.key, score: $0.value) }.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }
    }
}
