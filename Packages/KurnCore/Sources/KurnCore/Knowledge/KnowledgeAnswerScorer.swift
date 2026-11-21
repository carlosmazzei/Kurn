import Foundation

/// Scores one Ask answer against a golden question (K0.4/K5.4): which expected assertions it
/// states, which tempting ones it states anyway, whether it declined when it should and whether
/// every citation points at a real segment. Variants are compared on the `Summary` of a run.
public enum KnowledgeAnswerScorer {
    public struct Expectation: Equatable, Sendable {
        public let expected: Set<String>
        public let forbidden: Set<String>
        public let mustRefuse: Bool
        /// The `source/segment` IDs a grounded answer may cite.
        public let citable: Set<String>

        public init(expected: Set<String>, forbidden: Set<String>, mustRefuse: Bool, citable: Set<String>) {
            self.expected = expected
            self.forbidden = forbidden
            self.mustRefuse = mustRefuse
            self.citable = citable
        }
    }

    /// What an answer did, as judged against the fixture: the assertion references it states
    /// (expected or forbidden ones), claims matching neither and unsupported by the fixture, whether
    /// it declined, and the `source/segment` IDs it cites.
    public struct Observation: Equatable, Sendable {
        public let stated: Set<String>
        public let unsupportedClaims: Int
        public let refused: Bool
        public let cited: Set<String>

        public init(stated: Set<String>, unsupportedClaims: Int = 0, refused: Bool, cited: Set<String>) {
            self.stated = stated
            self.unsupportedClaims = max(0, unsupportedClaims)
            self.refused = refused
            self.cited = cited
        }
    }

    public struct Score: Equatable, Sendable {
        public let precision: Double
        public let recall: Double
        public let forbiddenStated: Int
        public let refusalHonoured: Bool
        public let citationsResolvable: Bool
        /// Cites only the question's citable segments, and cites at least one when it must state something.
        public let citationsGrounded: Bool
    }

    public struct Summary: Equatable, Sendable {
        public let questions: Int
        public let precision: Double
        public let recall: Double
        public let forbiddenStated: Int
        public let refusalsHonoured: Double
        public let citationsResolvable: Double
        public let citationsGrounded: Double
    }

    /// `resolvable` is every `source/segment` ID in the question's fixture.
    public static func score(_ observation: Observation, against expectation: Expectation, resolvable: Set<String>) -> Score {
        let correct = observation.stated.intersection(expectation.expected).count
        let claims = observation.stated.count + observation.unsupportedClaims
        return Score(precision: claims == 0 ? 1 : Double(correct) / Double(claims),
                     recall: expectation.expected.isEmpty ? 1 : Double(correct) / Double(expectation.expected.count),
                     forbiddenStated: observation.stated.intersection(expectation.forbidden).count,
                     refusalHonoured: observation.refused == expectation.mustRefuse,
                     citationsResolvable: observation.cited.isSubset(of: resolvable),
                     citationsGrounded: observation.cited.isSubset(of: expectation.citable)
                        && (expectation.expected.isEmpty || !observation.cited.isEmpty))
    }

    public static func summary(_ scores: [Score]) -> Summary {
        func mean(_ value: (Score) -> Double) -> Double {
            scores.isEmpty ? 0 : scores.map(value).reduce(0, +) / Double(scores.count)
        }
        return Summary(questions: scores.count, precision: mean(\.precision), recall: mean(\.recall),
                       forbiddenStated: scores.map(\.forbiddenStated).reduce(0, +),
                       refusalsHonoured: mean { $0.refusalHonoured ? 1 : 0 },
                       citationsResolvable: mean { $0.citationsResolvable ? 1 : 0 },
                       citationsGrounded: mean { $0.citationsGrounded ? 1 : 0 })
    }
}
