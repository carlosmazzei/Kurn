import Foundation

/// What an observer shows of a run, reduced from its events (NH05): the streamed text of the turn
/// being written (narration beside tool calls moves to the trace; the final text once the run finishes), its trace, its phase projection, the tool calls finished so far
/// and its outcome. A presentation snapshot, never a canonical record: canonical writes go
/// through the harness's awaited message and usage sinks, never through observation.
public struct AgentRunSnapshot: Sendable, Equatable {
    /// One finished tool call, in finish order.
    public struct FinishedTool: Sendable, Equatable {
        public let callID: String
        public let name: String
        public let isError: Bool
    }

    /// One part of the run's conversation (NH08): the run's own request, or a queued input it
    /// took in, with the reply to it — streamed, then the reply's final text.
    public struct Exchange: Sendable, Equatable {
        /// The queued input that opened it, by its item ID; nil for the run's own request.
        public let inputID: String?
        public let input: String?
        public fileprivate(set) var text = ""
    }

    /// A tool call the model is still writing (its arguments arrive in pieces): what has arrived
    /// so far, for display. It leaves the snapshot once the turn's message is final.
    public struct StreamingToolCall: Sendable, Equatable {
        public static let maxParsedScalars = 8_000
        public let blockID: String
        /// The identity its step keeps while the call is written, so a view can follow it.
        public let stepID = UUID()
        public fileprivate(set) var name: String
        /// The arguments so far, best effort (`AgentPartialJSON`) from their first
        /// `maxParsedScalars` scalars: what a title or a query needs, not a whole document.
        public fileprivate(set) var arguments: JSONValue?
        fileprivate var raw = ""
        fileprivate var rawScalars = 0

        fileprivate init(blockID: String, name: String) { self.blockID = blockID; self.name = name }

        fileprivate mutating func append(_ text: String) {
            guard rawScalars < Self.maxParsedScalars, !text.isEmpty else { return }
            let room = Self.maxParsedScalars - rawScalars
            let piece = String(String.UnicodeScalarView(text.unicodeScalars.prefix(room)))
            raw += piece
            rawScalars += piece.unicodeScalars.count
            arguments = AgentPartialJSON.parse(raw) ?? arguments
        }

        fileprivate mutating func replace(name: String, arguments text: String) {
            self.name = name
            raw = ""
            rawScalars = 0
            arguments = nil
            append(text)
        }

        /// A running tool step for a timeline to show while the call is written.
        public var step: AgentRunStep {
            var step = AgentRunStep(id: stepID, kind: .tool, status: .running)
            step.toolName = name
            step.arguments = arguments
            return step
        }
    }

    /// How many events this snapshot reflects.
    public private(set) var eventCount = 0
    public private(set) var text = ""
    public private(set) var trace = AgentRunTrace()
    public private(set) var progress = AgentRunProgress()
    /// Bounded by the run's tool-call limit, so an observer can find what finished since the
    /// snapshot it last saw by count.
    public private(set) var finishedTools: [FinishedTool] = []
    /// Tool calls of the turn being streamed, in the order they started.
    public private(set) var streamingToolCalls: [StreamingToolCall] = []
    public private(set) var outcome: AgentRunOutcome?
    /// The run's exchanges in order; more than one once it took in queued input.
    public private(set) var exchanges = [Exchange(inputID: nil, input: nil)]
    private var sawRequest = false

    public init() {}

    public mutating func apply(_ event: AgentEvent) {
        if case .runStarted = event { self = AgentRunSnapshot() }
        eventCount += 1
        trace.apply(event)
        progress.apply(event)
        switch event {
        case .textDelta(let delta):
            text += delta
            exchanges[exchanges.count - 1].text += delta
        case .messageAppended(.content(let message)) where message.role == .user:
            // The first user message is the run's request; each later one is queued input.
            if sawRequest { exchanges.append(Exchange(inputID: message.id, input: message.text)) }
            sawRequest = true
        case .messageAppended(.content(let message)) where message.role == .assistant:
            // A reply that calls no tool is the exchange's answer, replacing what streamed before it.
            // Text beside tool calls is narration, which the trace shows as its own step, so the
            // exchange's streamed text starts over for the next turn.
            if message.toolCalls.isEmpty, !message.text.isEmpty, Self.answers(message.stopReason) {
                exchanges[exchanges.count - 1].text = message.text
            } else if !message.toolCalls.isEmpty {
                text = ""
                exchanges[exchanges.count - 1].text = ""
            }
        case .modelContent(let content):
            applyStreaming(content)
        case .toolStarted, .requestStarted, .turnStarted:
            streamingToolCalls = []
        case .toolFinished(let callID, let name, _, let isError):
            finishedTools.append(FinishedTool(callID: callID, name: name, isError: isError))
        case .runFinished(let finished):
            streamingToolCalls = []
            text = finished.finalText
            outcome = finished
            if exchanges.count > 1 { exchanges[exchanges.count - 1].text = finished.finalText }
        default: break
        }
    }

    private mutating func applyStreaming(_ content: AgentContentEvent) {
        switch content {
        case .blockStarted(_, let block):
            guard case .toolCall(let call, _) = block.content else { return }
            var streaming = StreamingToolCall(blockID: block.id, name: call.name)
            streaming.append(call.rawArguments)
            streamingToolCalls.append(streaming)
        case .blockDelta(let id, .toolCall(_, let name, let arguments)):
            guard let index = streamingToolCalls.firstIndex(where: { $0.blockID == id }) else { return }
            streamingToolCalls[index].name += name ?? ""
            streamingToolCalls[index].append(arguments ?? "")
        case .blockUpdated(let block):
            // A finished call (Responses' `done`) or a whole call sent at once replaces what the
            // deltas built, keeping the step's identity.
            guard case .toolCall(let call, _) = block.content else { return }
            if let index = streamingToolCalls.firstIndex(where: { $0.blockID == block.id }) {
                streamingToolCalls[index].replace(name: call.name, arguments: call.rawArguments)
            } else {
                var streaming = StreamingToolCall(blockID: block.id, name: call.name)
                streaming.append(call.rawArguments)
                streamingToolCalls.append(streaming)
            }
        case .blockDelta:
            break
        case .messageFinished, .failed:
            streamingToolCalls = []
        }
    }

    private static func answers(_ reason: AgentModelStopReason?) -> Bool {
        switch reason {
        case .error?, .aborted?, .deferred?: return false
        default: return true
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
