import AgentHarness
import Foundation

/// A chat run's durable lifecycle marker (NH05). The chat saves the question first, then writes
/// this record as `.running` before any model request, and `.ended` once the run has settled. A
/// record still `.running` at launch belongs to a process that died mid-run (a crash, or a
/// suspension the background wind-down could not outrun): `ChatRunRecovery` marks it
/// `.interrupted`, and the saved question reopens as the retryable one. It is metadata only:
/// it never schedules, resumes or replays a run.
struct ChatRunRecord: Equatable, Sendable {
    enum State: String, Sendable { case running, ended, interrupted }

    let runID: String
    let questionTurnID: UUID
    /// ISO 8601 UTC, the same encoding as session entries.
    let startedAt: String
    var state: State

    init(runID: String, questionTurnID: UUID, startedAt: Date = Date(), state: State = .running) {
        self.runID = runID
        self.questionTurnID = questionTurnID
        self.startedAt = AgentSessionEntry.time(startedAt)
        self.state = state
    }

    /// Reads a run record; `nil` for any other kind, or a run record this version cannot read.
    init?(_ record: AgentRecoveryRecord) {
        guard record.kind == .run, case .object(let fields) = record.data,
              case .string(let rawState)? = fields["state"], let state = State(rawValue: rawState),
              case .string(let rawTurn)? = fields["questionTurnID"], let turn = UUID(uuidString: rawTurn),
              case .string(let startedAt)? = fields["startedAt"] else { return nil }
        runID = record.id
        questionTurnID = turn
        self.startedAt = startedAt
        self.state = state
    }

    func record() throws -> AgentRecoveryRecord {
        try AgentRecoveryRecord(id: runID, kind: .run, data: .object([
            "state": .string(state.rawValue),
            "questionTurnID": .string(questionTurnID.uuidString),
            "startedAt": .string(startedAt)
        ]))
    }
}
