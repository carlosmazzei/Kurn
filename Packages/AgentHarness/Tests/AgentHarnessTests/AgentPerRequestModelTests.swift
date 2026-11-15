import Foundation
import Testing
@testable import AgentHarness

/// NH07: credentials are resolved for every request, compaction summaries included.
@Suite struct AgentPerRequestModelTests {
    struct Revoked: Error {}

    /// Counts resolutions and can be told the credential was removed.
    final class Credentials: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var revoked = false
        var resolutions: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func revoke() {
            lock.lock(); defer { lock.unlock() }
            revoked = true
        }
        func resolve(_ model: ScriptedAgentModel) throws -> any AgentModel {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if revoked { throw Revoked() }
            return model
        }
    }

    @Test func everyRequestResolvesItsCredentialsAgain() async throws {
        let credentials = Credentials()
        let inner = ScriptedAgentModel([AgentTurnResponse(text: "", toolCalls: [agentCall()]), AgentTurnResponse(text: "Done")])
        let model = try AgentPerRequestModel { try credentials.resolve(inner) }
        #expect(credentials.resolutions == 1)
        let outcome = try agentOutcome(await agentEvents(NativeHarness(model: model), tools: [agentTool()]))
        #expect(outcome.finalText == "Done")
        // Once when created, then once per request.
        #expect(credentials.resolutions == 3)
    }

    @Test func aRevokedCredentialFailsTheNextRequest() async throws {
        let credentials = Credentials()
        let inner = ScriptedAgentModel([AgentTurnResponse(text: "Done")])
        let model = try AgentPerRequestModel { try credentials.resolve(inner) }
        credentials.revoke()
        await #expect(throws: Revoked.self) { try await agentEvents(NativeHarness(model: model)) }
        #expect(await inner.requests.isEmpty)
        // A credential missing from the start fails before any run.
        #expect(throws: Revoked.self) { try AgentPerRequestModel { throw Revoked() } }
    }
}
