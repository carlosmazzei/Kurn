import Foundation

/// Input a person adds while a run is working (NH08), in two FIFO queues. A *steering* message
/// enters the run after the current response and its whole tool batch, before the next request.
/// A *follow-up* waits until the run would otherwise finish — no tool calls left and no steering
/// pending — and then continues it. Each queue drains one item or all of them per boundary
/// (`Mode`). Every change persists the complete lists through `persist` before it is applied or
/// acknowledged, so an accepted item survives the process; an item becomes *executed* only when
/// the run drains it and commits it as a user message.
public actor AgentInputQueue {
    public enum Kind: String, Codable, Sendable { case steering, followUp }
    public enum Mode: String, Codable, Sendable { case one, all }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: Kind
        public var text: String
    }

    /// Both complete lists, in the order they will drain.
    public struct Snapshot: Codable, Sendable, Equatable {
        public var steering: [Item] = []
        public var followUp: [Item] = []
        public var isEmpty: Bool { steering.isEmpty && followUp.isEmpty }
        public init(steering: [Item] = [], followUp: [Item] = []) { self.steering = steering; self.followUp = followUp }
    }

    public enum QueueError: Error, Equatable { case emptyText, unknownItem }

    public let steeringMode: Mode
    public let followUpMode: Mode
    private let persist: @Sendable (Snapshot) async throws -> Void
    private var state: Snapshot
    private var observers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    /// Changes are serialized across the `persist` await, so two cannot build on the same lists.
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter persist: saves the complete lists; a throw rejects the change and leaves the
    ///   queue as it was.
    public init(restoring snapshot: Snapshot = Snapshot(), steeringMode: Mode = .all, followUpMode: Mode = .one,
                persist: @escaping @Sendable (Snapshot) async throws -> Void = { _ in }) {
        state = snapshot
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.persist = persist
    }

    public var snapshot: Snapshot { state }

    /// Every change as the complete lists, starting with the current ones.
    public func updates() -> AsyncStream<Snapshot> {
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    /// Accepts `text` into `kind`'s queue once the new lists are saved, and returns its item.
    @discardableResult
    public func enqueue(_ text: String, as kind: Kind) async throws -> Item {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QueueError.emptyText }
        let item = Item(id: UUID().uuidString, kind: kind, text: trimmed)
        await lock()
        defer { unlock() }
        var next = state
        switch kind {
        case .steering: next.steering.append(item)
        case .followUp: next.followUp.append(item)
        }
        try await apply(next)
        return item
    }

    /// Replaces a queued item's text, keeping its place and identity.
    public func edit(_ id: String, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QueueError.emptyText }
        await lock()
        defer { unlock() }
        var next = state
        if let index = next.steering.firstIndex(where: { $0.id == id }) { next.steering[index].text = trimmed }
        else if let index = next.followUp.firstIndex(where: { $0.id == id }) { next.followUp[index].text = trimmed }
        else { throw QueueError.unknownItem }
        try await apply(next)
    }

    public func remove(_ id: String) async throws {
        await lock()
        defer { unlock() }
        var next = state
        next.steering.removeAll { $0.id == id }
        next.followUp.removeAll { $0.id == id }
        guard next != state else { throw QueueError.unknownItem }
        try await apply(next)
    }

    /// Empties both queues and returns what they held, steering first, so a host can put it back
    /// in the person's draft before it stops the run.
    public func clear() async throws -> [Item] {
        await lock()
        defer { unlock() }
        let items = state.steering + state.followUp
        guard !items.isEmpty else { return [] }
        try await apply(Snapshot())
        return items
    }

    /// Takes the next items of `kind` for the run, by its mode; empty when nothing is queued.
    public func drain(_ kind: Kind) async throws -> [Item] {
        await lock()
        defer { unlock() }
        var next = state
        let taken: [Item]
        switch kind {
        case .steering:
            taken = steeringMode == .all ? next.steering : Array(next.steering.prefix(1))
            next.steering.removeFirst(taken.count)
        case .followUp:
            taken = followUpMode == .all ? next.followUp : Array(next.followUp.prefix(1))
            next.followUp.removeFirst(taken.count)
        }
        guard !taken.isEmpty else { return [] }
        try await apply(next)
        return taken
    }

    private func apply(_ next: Snapshot) async throws {
        try await persist(next)
        state = next
        for observer in observers.values { observer.yield(next) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    private func lock() async {
        guard locked else { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
}
