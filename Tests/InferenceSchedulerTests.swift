import XCTest
@testable import ReadingGlass

final class InferenceSchedulerTests: XCTestCase, @unchecked Sendable {
    func testOnlyOneOperationHoldsThePermit() async throws {
        let scheduler = InferenceScheduler()
        let activity = SchedulerActivity()
        let latch = SchedulerLatch()
        try await scheduler.acquire(.refinement)
        await activity.enter("owner")

        let jobs = (1...2).map { index in
            Task {
                try await scheduler.acquire(.refinement)
                await activity.enter("waiter-\(index)")
                await latch.wait()
                await activity.leave()
                await scheduler.release()
            }
        }
        try await waitForWaiters(2, in: scheduler)
        let beforeRelease = await activity.snapshot()
        XCTAssertEqual(beforeRelease.labels, ["owner"])
        XCTAssertEqual(beforeRelease.maximumActive, 1)

        await activity.leave()
        await scheduler.release()
        try await waitForEntries(2, in: activity)
        let firstGranted = await activity.snapshot()
        XCTAssertEqual(firstGranted.active, 1)
        XCTAssertEqual(firstGranted.maximumActive, 1)
        let remainingWaiters = await scheduler.waitingCount
        XCTAssertEqual(remainingWaiters, 1)

        await latch.open()
        for job in jobs { try await job.value }
        let finished = await activity.snapshot()
        XCTAssertEqual(finished.labels.count, 3)
        XCTAssertEqual(finished.active, 0)
        XCTAssertEqual(finished.maximumActive, 1)
    }

    func testWaitingTranslationPrecedesEarlierQueuedRefinement() async throws {
        let scheduler = InferenceScheduler()
        let activity = SchedulerActivity()
        try await scheduler.acquire(.refinement)

        let firstRefinement = queuedOperation("refinement-1", priority: .refinement,
                                              scheduler: scheduler, activity: activity)
        try await waitForWaiters(1, in: scheduler)
        let translation = queuedOperation("translation", priority: .translation,
                                          scheduler: scheduler, activity: activity)
        try await waitForWaiters(2, in: scheduler)
        let secondRefinement = queuedOperation("refinement-2", priority: .refinement,
                                               scheduler: scheduler, activity: activity)
        try await waitForWaiters(3, in: scheduler)

        await scheduler.release()
        try await firstRefinement.value
        try await translation.value
        try await secondRefinement.value
        let finished = await activity.snapshot()
        XCTAssertEqual(finished.labels, ["translation", "refinement-1", "refinement-2"])
        XCTAssertEqual(finished.maximumActive, 1)
    }

    func testCancelledWaiterIsRemovedWithoutWedgingThePermit() async throws {
        let scheduler = InferenceScheduler()
        let activity = SchedulerActivity()
        try await scheduler.acquire(.refinement)
        let cancelled = Task {
            do {
                try await scheduler.acquire(.translation)
                await scheduler.release()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        try await waitForWaiters(1, in: scheduler)
        let survivor = queuedOperation("survivor", priority: .refinement,
                                       scheduler: scheduler, activity: activity)
        try await waitForWaiters(2, in: scheduler)
        cancelled.cancel()
        let wasCancelled = await cancelled.value
        XCTAssertTrue(wasCancelled)
        try await waitForWaiters(1, in: scheduler)
        await scheduler.release()
        try await survivor.value

        let acquired = expectation(description: "Permit can be acquired again after cancellation")
        let next = Task {
            try await scheduler.acquire(.translation)
            acquired.fulfill()
            await scheduler.release()
        }
        await fulfillment(of: [acquired], timeout: 3)
        next.cancel()
        _ = await next.result
        let finished = await activity.snapshot()
        XCTAssertEqual(finished.labels, ["survivor"])
        let waiting = await scheduler.waitingCount
        XCTAssertEqual(waiting, 0)
    }

    func testAlreadyCancelledCallerCannotConsumeFreePermit() async throws {
        let scheduler = InferenceScheduler()
        let latch = SchedulerLatch()
        let caller = Task {
            await latch.wait()
            do {
                try await scheduler.acquire(.translation)
                await scheduler.release()
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        caller.cancel()
        await latch.open()
        let wasCancelled = await caller.value
        XCTAssertTrue(wasCancelled)
        try await scheduler.acquire(.refinement)
        await scheduler.release()
    }

    private func queuedOperation(_ label: String, priority: InferenceScheduler.Priority,
                                 scheduler: InferenceScheduler, activity: SchedulerActivity) -> Task<Void, Error> {
        Task {
            try await scheduler.acquire(priority)
            await activity.enter(label)
            await activity.leave()
            await scheduler.release()
        }
    }

    private func waitForWaiters(_ count: Int, in scheduler: InferenceScheduler) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await scheduler.waitingCount != count {
            guard ContinuousClock.now < deadline else {
                XCTFail("Waiters did not reach expected count \(count)")
                throw SchedulerTestError.timedOut
            }
            await Task.yield()
        }
    }

    private func waitForEntries(_ count: Int, in activity: SchedulerActivity) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await activity.snapshot().labels.count != count {
            guard ContinuousClock.now < deadline else {
                XCTFail("Granted operations did not reach expected count \(count)")
                throw SchedulerTestError.timedOut
            }
            await Task.yield()
        }
    }
}

private enum SchedulerTestError: Error { case timedOut }

private actor SchedulerLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor SchedulerActivity {
    struct Snapshot: Sendable {
        let labels: [String]
        let active: Int
        let maximumActive: Int
    }
    private var labels: [String] = []
    private var active = 0
    private var maximumActive = 0

    func enter(_ label: String) {
        labels.append(label)
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func leave() { active -= 1 }
    func snapshot() -> Snapshot {
        Snapshot(labels: labels, active: active, maximumActive: maximumActive)
    }
}
