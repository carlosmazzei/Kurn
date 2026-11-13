import Foundation

/// What an observer shows of a run, reduced from its events (NH05): the streamed text (the final
/// text once the run finishes), its trace, its phase projection, the tool calls finished so far
/// and its outcome. A presentation snapshot, never a canonical record: canonical writes go
/// through the harness's awaited message and usage sinks, never through observation.
public struct AgentRunSnapshot: Sendable, Equatable {
    /// One finished tool call, in finish order.
    public struct FinishedTool: Sendable, Equatable {
        public let callID: String
        public let name: String
        public let isError: Bool
    }

    /// How many events this snapshot reflects.
    public private(set) var eventCount = 0
    public private(set) var text = ""
    public private(set) var trace = AgentRunTrace()
    public private(set) var progress = AgentRunProgress()
    /// Bounded by the run's tool-call limit, so an observer can find what finished since the
    /// snapshot it last saw by count.
    public private(set) var finishedTools: [FinishedTool] = []
    public private(set) var outcome: AgentRunOutcome?

    public init() {}

    public mutating func apply(_ event: AgentEvent) {
        if case .runStarted = event { self = AgentRunSnapshot() }
        eventCount += 1
        trace.apply(event)
        progress.apply(event)
        switch event {
        case .textDelta(let delta): text += delta
        case .toolFinished(let callID, let name, _, let isError):
            finishedTools.append(FinishedTool(callID: callID, name: name, isError: isError))
        case .runFinished(let finished):
            text = finished.finalText
            outcome = finished
        default: break
        }
    }
}

public enum AgentRunSnapshots {
    /// Reduces `events` into snapshots and keeps only the newest for its observer: a slow observer
    /// skips intermediate snapshots instead of growing a queue, and never misses the last one,
    /// which is delivered before the stream ends with the run's failure, if any. The reduction
    /// drains `events` as fast as they come, so `events` should be a complete observation (no
    /// event is lost before it is reduced). Ending iteration stops the reduction, not the run.
    public static func coalescing(_ events: AsyncThrowingStream<AgentEvent, Error>)
        -> AsyncThrowingStream<AgentRunSnapshot, Error> {
        let (snapshots, continuation) = AsyncThrowingStream<AgentRunSnapshot, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let reducer = Task {
            var snapshot = AgentRunSnapshot()
            do {
                for try await event in events {
                    snapshot.apply(event)
                    continuation.yield(snapshot)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in reducer.cancel() }
        return snapshots
    }
}
