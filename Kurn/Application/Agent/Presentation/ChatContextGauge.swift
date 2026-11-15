import AgentHarness
import Foundation

/// How much of the model's window the conversation uses: the context the provider last reported
/// (`AgentRunProgress.contextTokens`) against the window the run resolved (its context step).
struct ChatContextGauge: Equatable {
    let usedTokens: Int
    let windowTokens: Int

    /// Nil when either side is unknown; the window is the newest one a run recorded.
    init?(usedTokens: Int?, steps: [[AgentRunStep]]) {
        guard let usedTokens, usedTokens > 0,
              let window = steps.reversed().lazy.compactMap({ $0.last { $0.contextResolution != nil }?.contextResolution })
                  .first?.contextWindowTokens, window > 0 else { return nil }
        self.usedTokens = usedTokens
        self.windowTokens = window
    }

    var fraction: Double { min(1, Double(usedTokens) / Double(windowTokens)) }
    var percent: Int { Int((fraction * 100).rounded()) }

    /// "12% · 125k / 1M", in the person's number format.
    var text: String { "\(percent)% · \(Self.compact(usedTokens)) / \(Self.compact(windowTokens))" }

    func accessibilityText(localize: (String) -> String) -> String {
        String(format: localize("chat.context.gauge.accessibility"), percent, Self.compact(windowTokens))
    }

    /// 950, 1.2k, 125k, 1.05M.
    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: return String(tokens)
        case ..<100_000: return (Double(tokens) / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "k"
        case ..<1_000_000: return String(Int((Double(tokens) / 1_000).rounded())) + "k"
        default: return (Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(0...2))) + "M"
        }
    }
}
