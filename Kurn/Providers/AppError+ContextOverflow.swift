import AgentHarness
import KurnCore

extension AppError: @retroactive AgentContextOverflowError {
    public var isContextOverflow: Bool {
        guard case .apiError(let status, let message) = self else { return false }
        return AgentContextOverflow.matches(statusCode: status, message: message)
    }
}
