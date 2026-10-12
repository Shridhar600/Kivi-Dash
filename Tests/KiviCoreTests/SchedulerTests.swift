import Foundation
import Testing

@testable import KiviCore

@Suite("Scheduler")
struct SchedulerTests {
    /// An actor rather than a locked class: Swift 6 concurrency is happier with
    /// this than with a mutable reference type behind a lock.
    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    @Test("default interval is thirty minutes")
    func defaultInterval() {
        #expect(IngestInterval.defaultSeconds == 30 * 60)
    }

    @Test("runs immediately on start and then repeats on the interval")
    func cadence() async throws {
        let counter = Counter()
        let scheduler = IngestScheduler(intervalSeconds: 1) {
            await counter.increment()
            return IngestPipeline.Output(result: IngestResult(outcome: .ok))
        }

        await scheduler.start()
        // The first run happens before the first sleep, so the popover is
        // populated as soon as the app appears.
        try await Task.sleep(for: .milliseconds(200))
        let early = await counter.count
        #expect(early >= 1, "first run must be immediate")

        try await Task.sleep(for: .milliseconds(2_400))
        await scheduler.stop()
        let afterTwoSeconds = await counter.count
        #expect(afterTwoSeconds >= 2, "expected a repeat run, got \(afterTwoSeconds)")

        // Stopping must actually stop it.
        try await Task.sleep(for: .milliseconds(1_400))
        #expect(await counter.count == afterTwoSeconds, "stop() must end the loop")
        #expect(await scheduler.isRunning == false)
    }

    @Test("start is idempotent")
    func startTwice() async throws {
        let counter = Counter()
        let scheduler = IngestScheduler(intervalSeconds: 60) {
            await counter.increment()
            return IngestPipeline.Output(result: IngestResult(outcome: .ok))
        }

        await scheduler.start()
        await scheduler.start()
        try await Task.sleep(for: .milliseconds(200))
        let runs = await counter.count
        #expect(runs == 1, "a second start must not spawn a second loop")
        await scheduler.stop()
    }

    @Test("a throwing ingest becomes a failed result rather than propagating")
    func failuresDoNotEscape() async throws {
        struct Boom: Error {}
        let scheduler = IngestScheduler(intervalSeconds: 60) {
            throw Boom()
        }

        let output = await scheduler.runOnce()
        #expect(output.result.outcome == .failedError)
        #expect(!output.result.detail.isEmpty)
    }
}
