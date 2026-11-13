import AgentHarness
import KurnCore

/// Which provider failures the agent session may retry (NH07, `AgentRetryPolicy`): the same
/// transient statuses and connection failures the transport's own retry uses, never a timeout or
/// lost connection the provider may already be generating for, and never authentication,
/// configuration, quota or context errors. The agent transport keeps its own retries off, so the
/// session is the one retry owner.
extension AppError: @retroactive AgentTransientError {
    public var isTransient: Bool {
        switch self {
        case .apiError(let status, _): return LLMHTTP.retriableStatusCodes.contains(status)
        case .networkError(let urlError):
            return !LLMHTTP.ambiguousURLErrorCodes.contains(urlError.code)
                && LLMHTTP.retriableURLErrorCodes.contains(urlError.code)
        default: return false
        }
    }

    /// Always nil: `AppError` has no field for it. The agent stream attaches the response's
    /// `Retry-After` as an `AgentRetryAfter` around this error (`LLMHTTP.streamAgent`).
    public var retryAfterSeconds: Double? { nil }
}
