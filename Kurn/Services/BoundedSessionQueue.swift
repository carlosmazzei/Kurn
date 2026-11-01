import Foundation
import Synchronization

final class BoundedSessionQueue<Element: Sendable>: Sendable {
    struct Token: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    struct Snapshot: Sendable {
        let isAccepting: Bool
        let count: Int
        let cost: Double
        let droppedCount: Int
    }

    private struct Entry: Sendable {
        let element: Element
        let cost: Double
    }

    private struct State: Sendable {
        var token: Token?
        var isAccepting = false
        var entries: [Entry] = []
        var cost: Double = 0
        var droppedCount = 0
        var waiter: CheckedContinuation<Element?, Never>?
    }

    private let maximumCost: Double
    private let storage = Mutex(State())

    init(maximumCost: Double = 8) {
        precondition(maximumCost.isFinite && maximumCost > 0)
        self.maximumCost = maximumCost
    }

    func begin() -> Token {
        let token = Token()
        let waiter = storage.withLock { state in
            let waiter = state.waiter
            state = State(token: token)
            return waiter
        }
        waiter?.resume(returning: nil)
        return token
    }

    @discardableResult
    func activate(_ token: Token) -> Bool {
        storage.withLock { state in
            guard state.token == token else { return false }
            state.isAccepting = true
            return true
        }
    }

    var receivingToken: Token? {
        storage.withLock { $0.isAccepting ? $0.token : nil }
    }

    func isCurrent(_ token: Token) -> Bool {
        storage.withLock { $0.token == token }
    }

    var snapshot: Snapshot {
        storage.withLock {
            Snapshot(isAccepting: $0.isAccepting, count: $0.entries.count, cost: $0.cost, droppedCount: $0.droppedCount)
        }
    }

    @discardableResult
    func enqueue(_ element: Element, cost: Double, for token: Token) -> Bool {
        guard cost.isFinite, cost > 0, cost <= maximumCost else { return false }
        let result = storage.withLock { state -> (Bool, CheckedContinuation<Element?, Never>?) in
            guard state.token == token, state.isAccepting else { return (false, nil) }
            if let waiter = state.waiter {
                state.waiter = nil
                return (true, waiter)
            }
            while state.cost > maximumCost - cost, !state.entries.isEmpty {
                state.cost -= state.entries.removeFirst().cost
                state.droppedCount += 1
                if state.entries.isEmpty { state.cost = 0 }
            }
            state.entries.append(Entry(element: element, cost: cost))
            state.cost += cost
            return (true, nil)
        }
        result.1?.resume(returning: element)
        return result.0
    }

    func next(for token: Token) async -> Element? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result = storage.withLock { state -> (resume: Bool, element: Element?) in
                    guard state.token == token, state.isAccepting else { return (true, nil) }
                    if !state.entries.isEmpty {
                        let entry = state.entries.removeFirst()
                        state.cost -= entry.cost
                        if state.entries.isEmpty { state.cost = 0 }
                        return (true, entry.element)
                    }
                    guard state.waiter == nil else { return (true, nil) }
                    state.waiter = continuation
                    return (false, nil)
                }
                if result.resume { continuation.resume(returning: result.element) }
            }
        } onCancel: {
            self.invalidate(token)
        }
    }

    @discardableResult
    func invalidate(_ token: Token? = nil) -> Bool {
        let result = storage.withLock { state -> (Bool, CheckedContinuation<Element?, Never>?) in
            guard token == nil || state.token == token else { return (false, nil) }
            let waiter = state.waiter
            state = State()
            return (true, waiter)
        }
        result.1?.resume(returning: nil)
        return result.0
    }
}
