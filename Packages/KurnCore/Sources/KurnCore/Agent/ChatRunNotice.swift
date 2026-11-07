import AgentHarness
import Foundation

public enum ChatRunNotice {
    public static func needsRetry(steps: [ChatAgentStep], answer: String) -> Bool {
        guard let reason = steps.last(where: { $0.kind == .stop })?.stopReason else { return false }
        return reason != .completed && answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func text(steps: [ChatAgentStep], hasAnswer: Bool, localize: (String) -> String) -> String? {
        guard let step = steps.last(where: { $0.kind == .stop }), let reason = step.stopReason, reason != .completed else { return nil }
        return String(format: localize(hasAnswer ? "chat.limit.stopped" : "chat.limit.retry"),
                      ChatStepPresentation(step: step).title(localize: localize))
    }
}
