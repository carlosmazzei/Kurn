import AgentHarness
import Foundation
import KurnCore

actor ChatAgentModel: AgentModel {
    enum Failure: Error { case provider, exhausted }
    let responses: [AgentTurnResponse]
    let pauseAt: Int?
    let appError: AppError?
    let fails: Bool
    private(set) var requests: [AgentTurnRequest] = []
    private(set) var wasCancelled = false

    init(_ responses: [AgentTurnResponse] = [], pauseAt: Int? = nil, appError: AppError? = nil, fails: Bool = false) {
        self.responses = responses
        self.pauseAt = pauseAt
        self.appError = appError
        self.fails = fails
    }

    func streamTurn(_ request: AgentTurnRequest,
                    onEvent: @escaping @Sendable (AgentModelEvent) -> Void) async throws -> AgentTurnResponse {
        let index = requests.count
        requests.append(request)
        if let appError { throw appError }
        if fails { throw Failure.provider }
        guard responses.indices.contains(index) else { throw Failure.exhausted }
        let response = responses[index]
        onEvent(.textDelta(response.text))
        if pauseAt == index {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { wasCancelled = true; throw error }
        }
        return response
    }
}

func chatAgentCall(_ name: String, arguments: JSONValue = .object([:]), id: String = UUID().uuidString) throws -> AgentToolCall {
    AgentToolCall(id: id, name: name, arguments: .null, rawArguments: try arguments.encodedString())
}
