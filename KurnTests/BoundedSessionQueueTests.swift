import Foundation
import Testing
@testable import Kurn

struct BoundedSessionQueueTests {
    @Test func idleAndLoadingSessionsDoNotAcceptElements() async {
        let queue = BoundedSessionQueue<Int>()
        #expect(queue.receivingToken == nil)
        #expect(!queue.snapshot.isAccepting)
        let token = queue.begin()
        #expect(queue.isCurrent(token))
        #expect(queue.receivingToken == nil)
        #expect(!queue.enqueue(1, cost: 1, for: token))
        #expect(await queue.next(for: token) == nil)
        #expect(queue.snapshot.count == 0)
        #expect(queue.snapshot.droppedCount == 0)
        queue.invalidate()
    }

    @Test func buffersRemainOrderedWhileThePumpIsBusy() async {
        let queue = BoundedSessionQueue<Int>()
        let token = queue.begin()
        #expect(queue.activate(token))
        #expect(queue.receivingToken == token)
        queue.enqueue(1, cost: 1, for: token)
        #expect(await queue.next(for: token) == 1)
        for value in 2...8 { #expect(queue.enqueue(value, cost: 1, for: token)) }
        #expect(queue.snapshot.count == 7)
        #expect(queue.snapshot.cost == 7)
        #expect(queue.snapshot.droppedCount == 0)
        for value in 2...8 { #expect(await queue.next(for: token) == value) }
        #expect(queue.snapshot.cost == 0)
        queue.invalidate()
    }

    @Test func theExactBacklogLimitRetainsEveryElementAndOverflowDropsOnlyOldest() async {
        let queue = BoundedSessionQueue<Int>(maximumCost: 3)
        let token = queue.begin()
        queue.activate(token)
        for value in 1...3 { queue.enqueue(value, cost: 1, for: token) }
        #expect(queue.snapshot.count == 3)
        #expect(queue.snapshot.cost == 3)
        #expect(queue.snapshot.droppedCount == 0)
        queue.enqueue(4, cost: 1, for: token)
        #expect(queue.snapshot.count == 3)
        #expect(queue.snapshot.cost == 3)
        #expect(queue.snapshot.droppedCount == 1)
        for value in 2...4 { #expect(await queue.next(for: token) == value) }
        queue.invalidate()
    }

    @Test func variableCostsEvictOnlyEnoughOldAudioToFit() async {
        let queue = BoundedSessionQueue<Int>(maximumCost: 8)
        let token = queue.begin()
        queue.activate(token)
        queue.enqueue(1, cost: 3, for: token)
        queue.enqueue(2, cost: 3, for: token)
        queue.enqueue(3, cost: 2, for: token)
        queue.enqueue(4, cost: 4, for: token)
        #expect(queue.snapshot.cost == 6)
        #expect(queue.snapshot.count == 2)
        #expect(queue.snapshot.droppedCount == 2)
        #expect(await queue.next(for: token) == 3)
        #expect(await queue.next(for: token) == 4)
        queue.invalidate()
    }

    @Test(arguments: [0.0, -1, Double.nan, .infinity, -.infinity, 9])
    func invalidOrOversizedCostsDoNotDisturbAlreadyQueuedAudio(cost: Double) async {
        let queue = BoundedSessionQueue<Int>(maximumCost: 8)
        let token = queue.begin()
        queue.activate(token)
        queue.enqueue(1, cost: 1, for: token)
        #expect(!queue.enqueue(2, cost: cost, for: token))
        #expect(queue.snapshot.count == 1)
        #expect(queue.snapshot.cost == 1)
        #expect(queue.snapshot.droppedCount == 0)
        #expect(await queue.next(for: token) == 1)
        queue.invalidate()
    }

    @Test func fractionalBacklogsStayBoundedAndAllDropsAreCounted() {
        let queue = BoundedSessionQueue<Int>(maximumCost: 8)
        let token = queue.begin()
        queue.activate(token)
        for value in 0..<1_000 { queue.enqueue(value, cost: 0.02, for: token) }
        let snapshot = queue.snapshot
        #expect(snapshot.cost <= 8)
        #expect(snapshot.count <= 400)
        #expect(snapshot.count + snapshot.droppedCount == 1_000)
        queue.invalidate()
    }

    @Test func emptyEnqueueRacesAlwaysWakeTheSinglePump() async {
        let queue = BoundedSessionQueue<Int>()
        let token = queue.begin()
        queue.activate(token)
        for value in 0..<100 {
            let waiting = Task { await queue.next(for: token) }
            if value.isMultiple(of: 2) { await Task.yield() }
            #expect(queue.enqueue(value, cost: 1, for: token))
            #expect(await waiting.value == value)
            #expect(queue.snapshot.count == 0)
        }
        queue.invalidate()
    }

    @Test func stoppingWakesAnEmptyPumpAndClearsTheSession() async {
        let queue = BoundedSessionQueue<Int>()
        let token = queue.begin()
        queue.activate(token)
        let waiting = Task { await queue.next(for: token) }
        await Task.yield()
        #expect(queue.invalidate(token))
        #expect(await waiting.value == nil)
        #expect(!queue.isCurrent(token))
        #expect(queue.receivingToken == nil)
        #expect(queue.snapshot.count == 0)
        #expect(!queue.enqueue(1, cost: 1, for: token))
    }

    @Test func restartingReleasesAnOldWaiterAndRejectsEveryStaleOperation() async {
        let queue = BoundedSessionQueue<Int>()
        let old = queue.begin()
        queue.activate(old)
        let waiting = Task { await queue.next(for: old) }
        await Task.yield()
        let current = queue.begin()
        #expect(await waiting.value == nil)
        #expect(queue.activate(current))
        queue.enqueue(42, cost: 1, for: current)
        #expect(!queue.activate(old))
        #expect(!queue.enqueue(1, cost: 1, for: old))
        #expect(await queue.next(for: old) == nil)
        #expect(!queue.invalidate(old))
        #expect(queue.isCurrent(current))
        #expect(queue.snapshot.count == 1)
        #expect(await queue.next(for: current) == 42)
        queue.invalidate()
    }

    @Test func cancellationBeforeOrDuringWaitingReleasesThePump() async {
        let queue = BoundedSessionQueue<Int>()
        let token = queue.begin()
        queue.activate(token)
        let waiting = Task { await queue.next(for: token) }
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(!queue.isCurrent(token))
        #expect(queue.receivingToken == nil)
    }

    @Test func anOldPumpsCancellationCannotClearANewSessionsBacklog() async {
        let queue = BoundedSessionQueue<Int>()
        let old = queue.begin()
        queue.activate(old)
        let waiting = Task { await queue.next(for: old) }
        let current = queue.begin()
        queue.activate(current)
        queue.enqueue(42, cost: 1, for: current)
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(queue.isCurrent(current))
        #expect(queue.snapshot.count == 1)
        #expect(await queue.next(for: current) == 42)
        queue.invalidate()
    }

    @Test func concurrentProducersKeepEveryAcceptedElementWithoutSpawningConsumers() async {
        let queue = BoundedSessionQueue<Int>(maximumCost: 128)
        let token = queue.begin()
        queue.activate(token)
        await withTaskGroup(of: Bool.self) { group in
            for value in 0..<100 {
                group.addTask { queue.enqueue(value, cost: 1, for: token) }
            }
            for await accepted in group { #expect(accepted) }
        }
        #expect(queue.snapshot.count == 100)
        #expect(queue.snapshot.droppedCount == 0)
        var values: Set<Int> = []
        for _ in 0..<100 {
            if let value = await queue.next(for: token) { values.insert(value) }
        }
        #expect(values == Set(0..<100))
        #expect(queue.snapshot.cost == 0)
        queue.invalidate()
    }
}
