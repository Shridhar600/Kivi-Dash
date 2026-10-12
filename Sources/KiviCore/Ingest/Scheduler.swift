import Foundation
import os

/// The refresh interval.
///
/// A `let` rather than a mutable static: Swift 6 language mode rejects shared
/// mutable global state outright, which is the right call. Change it here, or
/// pass a different value to `IngestScheduler(intervalSeconds:)`.
public enum IngestInterval {
    public static let defaultSeconds: UInt64 = 30 * 60
}

/// Runs ingest on launch and then on a loop.
///
/// `Task.sleep` rather than `Timer`: timer callbacks are hostile to strict
/// concurrency and need a run loop this app does not otherwise own.
public actor IngestScheduler {
    /// Injected so the cadence can be tested without touching Kivi's real store.
    private let ingest: @Sendable () async throws -> IngestPipeline.Output
    private let intervalSeconds: UInt64
    private let logger = Logger(subsystem: AppPaths.bundleIdentifier, category: "scheduler")
    private var task: Task<Void, Never>?
    private var onIngest: (@Sendable () async -> Void)?

    public init(pipeline: IngestPipeline, intervalSeconds: UInt64 = IngestInterval.defaultSeconds) {
        self.ingest = { try await Task.detached(priority: .utility) { try pipeline.run() }.value }
        self.intervalSeconds = intervalSeconds
    }

    /// Test seam: runs `body` on the same cadence without a pipeline.
    public init(
        intervalSeconds: UInt64,
        onRun: @escaping @Sendable () async throws -> IngestPipeline.Output
    ) {
        self.ingest = onRun
        self.intervalSeconds = intervalSeconds
    }

    /// Derived from the task itself rather than a separate flag, which could
    /// disagree with reality if the loop ever returned without going via `stop()`.
    public var isRunning: Bool { task != nil }

    /// Registers a callback invoked after every ingest pass.
    ///
    /// Without this the menu bar's health icon only ever updates when the popover
    /// happens to be opened, because nothing else re-reads the status. A schema
    /// drift would produce `.failedSchema` and a red octagon that never appeared,
    /// unless the user happened to open the panel in the last 30 minutes — which
    /// is precisely the failure the whole schema-contract design exists to
    /// surface.
    public func setIngestObserver(_ observer: (@Sendable () async -> Void)?) {
        onIngest = observer
    }

    /// Starts the loop. The first run is immediate so the menu is populated as
    /// soon as the app appears rather than 30 minutes later.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.loop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            await runOnce()
            await onIngest?()
            do {
                try await Task.sleep(for: .seconds(intervalSeconds))
            } catch {
                // Cancellation is the expected way out of this loop.
                logger.debug("scheduler loop cancelled")
                return
            }
        }
    }

    /// One ingest pass. Never throws: a failure here must not take down a
    /// menu bar app that has no window to show an error in.
    @discardableResult
    public func runOnce() async -> IngestPipeline.Output {
        do {
            let output = try await ingest()
            let summary =
                "\(output.result.rowsNew) new, \(output.result.rowsRetired) retired, \(output.result.daysRebuilt) days rebuilt"
            logger.info("ingest \(output.result.outcome.rawValue, privacy: .public): \(summary, privacy: .public)")
            return output
        } catch {
            // Not marked `.public`: the error carries the database path, and the
            // unified log is machine-readable by other processes on the machine.
            // Redaction is free; an unredacted `/Users/<name>/...` is not.
            logger.error("ingest failed: \(String(describing: error), privacy: .private)")
            return IngestPipeline.Output(
                result: IngestResult(outcome: .failedError, detail: String(describing: error))
            )
        }
    }
}
