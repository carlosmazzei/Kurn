import Foundation

public extension NativeHarness {
    /// Configure the standalone runtime with a model's resolved capacity.
    /// The same script-aware defaults apply with or without an app adapter.
    init(model: any AgentModel, contextWindow: Int,
         limits: AgentLimits = AgentLimits(), costEstimator: (@Sendable (AgentUsage) -> Double)? = nil,
         reserveTokens: Int = AgentContextPolicy.defaultReserveTokens,
         keepRecentTokens: Int = AgentContextPolicy.defaultKeepRecentTokens,
         confirm: @escaping @Sendable (AgentToolCall) async -> Bool = { _ in false },
         diagnosticSink: @escaping @Sendable (AgentDiagnostic) -> Void = { _ in }) {
        self.init(model: model, limits: limits, costEstimator: costEstimator,
                  contextPolicy: AgentContextPolicy(contextWindow: contextWindow, reserveTokens: reserveTokens,
                                                    keepRecentTokens: keepRecentTokens),
                  confirm: confirm, diagnosticSink: diagnosticSink)
    }
}
