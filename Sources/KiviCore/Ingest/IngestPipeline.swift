import Foundation
import SQLite3
import os

/// The whole ingest pipeline, in the order that makes the privacy guarantee
/// structural rather than a matter of discipline:
///
///     locate → snapshot → validate → extract → load/rollup → discard snapshot
///
/// `extract` is its own stage precisely so the transcript exists only inside one
/// function's stack frame. No table — including a `TEMP` table — has a column
/// capable of holding it.
public struct IngestPipeline: Sendable {
    public struct Output: Sendable {
        public var result: IngestResult
        public var incognitoNow: Bool?
        public var coverage: CoverageSampler.Sample?
    }

    private let paths: AppPaths
    private let logger = Logger(subsystem: AppPaths.bundleIdentifier, category: "ingest")

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func run(now: Date = Date(), timezone: TimeZone = .current) throws -> Output {
        var result = IngestResult(outcome: .ok)

        // Clear anything a crash or force-quit orphaned. Each orphan is a full
        // copy of the dictation history; without this they accumulate forever.
        let orphans = Snapshot.sweep(directory: paths.snapshotDirectory)
        if orphans > 0 {
            logger.notice("removed \(orphans, privacy: .public) orphaned snapshot(s)")
        }

        let source: URL
        do {
            source = try paths.locateSourceStore()
        } catch {
            // Kivi may simply never have run. Keep the last good data.
            logger.info("source not found: \(String(describing: error))")
            return Output(result: IngestResult(outcome: .skippedNoSource, detail: "Kivi store not found"))
        }

        // Sampling prefs before the snapshot is fine; prefs are not the bottleneck.
        let coverageSample = CoverageSampler.sample(home: paths.home)

        let snapshotURL: URL
        do {
            snapshotURL = try Snapshot.take(from: source, into: paths.snapshotDirectory)
        } catch {
            logger.error("snapshot failed: \(String(describing: error))")
            result.outcome = (error as? DatabaseError).map { _ in .skippedBusy } ?? .failedError
            result.detail = "could not snapshot Kivi's database"
            return Output(result: result, incognitoNow: coverageSample.incognitoNow, coverage: coverageSample)
        }

        // From here on the snapshot is the only thing we read, and it holds text.
        defer { Snapshot.discard(snapshotURL) }

        let snapshot: Database
        do {
            snapshot = try Database(path: snapshotURL.path, readOnly: true)
        } catch {
            result.outcome = .failedError
            result.detail = "snapshot unreadable"
            return Output(result: result, incognitoNow: coverageSample.incognitoNow, coverage: coverageSample)
        }

        // Drift check first: a missing column must never be read as "zero takes".
        let contract: SchemaContract.Outcome
        do {
            contract = try SchemaContract.validate(snapshot)
        } catch {
            result.outcome = .failedError
            result.detail = "could not inspect Kivi's schema"
            return Output(result: result, incognitoNow: coverageSample.incognitoNow, coverage: coverageSample)
        }

        guard contract.canProceed else {
            result.outcome = .failedSchema
            result.detail = contract.detail
            logger.error("schema drift: \(contract.detail)")
            return Output(result: result, incognitoNow: coverageSample.incognitoNow, coverage: coverageSample)
        }

        let takes: [ExtractedTake]
        do {
            takes = try Extractor.extract(from: snapshot, timezone: timezone)
        } catch {
            result.outcome = .failedError
            result.detail = "could not read takes from snapshot"
            return Output(result: result, incognitoNow: coverageSample.incognitoNow, coverage: coverageSample)
        }

        let target: Database
        do {
            try paths.prepareDirectories()
            target = try Database(path: paths.database.path)
            try Schema.apply(to: target)
            // After the schema step, because that is what creates the file and its
            // WAL sidecars. SQLite creates them 0644 on a stock macOS; this is the
            // second lock on data that includes every bundle id you have dictated
            // into. Best-effort by design — a filesystem that refuses chmod is not
            // a reason to abandon the ingest.
            paths.secureDatabasePermissions()
        } catch {
            result.outcome = .failedError
            result.detail = "could not open our own database"
            return Output(result: result, incognitoNow: coverageSample.incognitoNow, coverage: coverageSample)
        }

        do {
            try CoverageSampler.record(coverageSample, in: target, now: now)
        } catch {
            logger.error("coverage sampling failed: \(String(describing: error))")
        }

        let hash = (try? SchemaContract.hash(snapshot)) ?? ""
        let modelVersion = try? snapshot.scalarInt64("SELECT Z_VERSION FROM Z_METADATA")

        result =
            try Ingestor.run(
                target: target,
                takes: takes,
                timezone: timezone,
                now: now,
                storePath: source.path,
                kiviAppVersion: KiviAppInfo.appVersion(),
                kiviModelVersion: modelVersion.map(String.init),
                schemaHash: hash,
                kiviInstallationID: coverageSample.installID,
                incognitoNow: coverageSample.incognitoNow,
                takeSuccess: coverageSample.takeSuccess
            )

        return Output(result: result, incognitoNow: coverageSample.incognitoNow, coverage: coverageSample)
    }
}

/// Kivi's bundle metadata, read straight from the plist.
public enum KiviAppInfo {
    public static func appPath() -> URL {
        URL(fileURLWithPath: "/Applications/Kivi.app")
    }

    public static func appVersion() -> String? {
        plistValue("CFBundleShortVersionString") as? String
    }

    private static func plistValue(_ key: String) -> Any? {
        let plist = appPath().appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return dictionary[key]
    }
}
