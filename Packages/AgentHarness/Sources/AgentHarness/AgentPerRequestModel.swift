import Foundation

/// A model whose credentials are resolved for every request (NH07), compaction summaries
/// included: `resolve` builds the vendor client each time, so a key replaced while a run is in
/// progress is used from the next request on, and a key removed fails that request explicitly
/// instead of the run carrying a stale one. The descriptor is fixed, from the first resolution.
public struct AgentPerRequestModel: AgentModel {
    public let descriptor: AgentModelDescriptor?
    private let resolve: @Sendable () throws -> any AgentModel

    /// Resolves once now, so a missing credential fails before the run starts.
    public init(resolve: @escaping @Sendable () throws -> any AgentModel) throws {
        descriptor = try resolve().descriptor
        self.resolve = resolve
    }

    public func streamTurn(_ request: AgentTurnRequest,
                           onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
        try await resolve().streamTurn(request, onEvent: onEvent)
    }
}
