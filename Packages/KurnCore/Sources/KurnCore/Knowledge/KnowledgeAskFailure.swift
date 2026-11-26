import Foundation

/// Why an Ask answer over knowledge fell short of its golden question (K7.0). The classes order
/// the K7 steps: no layer is built on a guessed cause, only on the class the measured failures
/// of the question set fall into most.
public enum KnowledgeAskFailureClass: String, CaseIterable, Codable, Sendable {
    /// An expected assertion is not in the compiled knowledge at all: the extractor missed it,
    /// or the meeting was never compiled. No query layer can recover it.
    case extraction
    /// Every expected assertion was compiled, but their entities do not form one neighbourhood
    /// (each meeting's "Portal" is its own node), so no walk joins them.
    case island
    /// The facts were compiled and connected but the run never surfaced all of them: it stopped
    /// or abandoned the chain of calls (resolve, graph, timeline, evidence) midway.
    case lostHop
    /// The facts were surfaced but read at the wrong clock: valid time taken for recorded time,
    /// the state after a date asked "as of" it, or the order of a change misjudged.
    case temporal

    /// The K7 step that addresses this class when it dominates the measured failures.
    public var remedy: String {
        switch self {
        case .extraction: "cloud-extraction decision"
        case .island: "K7.4/K7.6"
        case .lostHop: "K7.3"
        case .temporal: "K7.1/K7.2"
        }
    }
}

public enum KnowledgeAskFailureClassifier {
    /// What the run is known to have done, judged against the question's fixture, besides its answer.
    public struct Diagnosis: Equatable, Sendable {
        /// The expected assertion references present in the compiled knowledge.
        public let compiled: Set<String>
        /// Whether the compiled expected assertions' entities form one connected neighbourhood.
        public let connected: Bool
        /// The expected assertion references the run's tool results surfaced.
        public let retrieved: Set<String>
        /// Whether a claim was stated at the wrong clock (a stated start taken for the date
        /// it was recorded, or the state after the asked "as of" day).
        public let clockMismatch: Bool

        public init(compiled: Set<String>, connected: Bool, retrieved: Set<String>, clockMismatch: Bool) {
            self.compiled = compiled
            self.connected = connected
            self.retrieved = retrieved
            self.clockMismatch = clockMismatch
        }
    }

    /// The class of a failed answer, or nil when it states every expected assertion and nothing
    /// forbidden. The causes are tried from the one furthest upstream, since a downstream symptom
    /// follows from it: extraction, then islands, then a clock mix-up, then a lost hop.
    public static func classify(_ score: KnowledgeAnswerScorer.Score, expectation: KnowledgeAnswerScorer.Expectation,
                                diagnosis: Diagnosis) -> KnowledgeAskFailureClass? {
        guard score.recall < 1 || score.precision < 1 || score.forbiddenStated > 0 else { return nil }
        if !expectation.expected.isSubset(of: diagnosis.compiled) { return .extraction }
        if !diagnosis.connected && expectation.expected.count > 1 { return .island }
        if diagnosis.clockMismatch { return .temporal }
        if !expectation.expected.isSubset(of: diagnosis.retrieved) { return .lostHop }
        return .temporal
    }

    /// Failures counted per class, the dominant class first (ties in declaration order), with the
    /// classes that never failed left out.
    public static func ranked(_ failures: [KnowledgeAskFailureClass]) -> [(failure: KnowledgeAskFailureClass, count: Int)] {
        var counts: [KnowledgeAskFailureClass: Int] = [:]
        for failure in failures { counts[failure, default: 0] += 1 }
        var result: [(failure: KnowledgeAskFailureClass, count: Int)] = []
        for failure in KnowledgeAskFailureClass.allCases {
            if let count = counts[failure] { result.append((failure: failure, count: count)) }
        }
        // `sorted` is not documented as stable, so ties are broken by declaration order explicitly.
        let order = KnowledgeAskFailureClass.allCases
        return result.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return (order.firstIndex(of: left.failure) ?? 0) < (order.firstIndex(of: right.failure) ?? 0)
        }
    }
}
