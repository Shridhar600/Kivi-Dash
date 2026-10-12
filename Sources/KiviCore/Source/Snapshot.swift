import Foundation

/// Takes a throwaway, consistent copy of Kivi's live database.
///
/// Why a snapshot at all:
/// * Kivi's store is in WAL mode and is being written while we read. The WAL is
///   routinely larger than the main database file.
/// * Copying the main file alone, or opening the source `immutable=1`, silently
///   returns a stale view — every write since the last checkpoint is lost, with
///   no error. That failure mode is indistinguishable from "Kivi deleted my
///   history", which is exactly the bug this avoids.
/// * The snapshot is the only artefact that contains transcript text, so it is
///   created private to the user and deleted immediately after the ingest
///   transaction commits.
public enum Snapshot {
    static let prefix = "kivi-snapshot-"

    /// Copies `source` into a fresh file in `directory` and returns its URL.
    ///
    /// If any step throws, the partially-written copy is removed before the
    /// error propagates. Without that, a failure here leaves a transcript-bearing
    /// file on disk that no caller ever learns about — the caller cannot even
    /// register its own cleanup, because `take` never returned a URL.
    public static func take(from source: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory does not tighten an existing directory, so re-assert
        // the mode: a directory created by an older build must not stay readable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let destination = directory.appendingPathComponent("\(prefix)\(UUID().uuidString).db")
        try? FileManager.default.removeItem(at: destination)

        // Create the file with 0600 *before* the first byte is written, so the
        // transcript is never world-readable even for the duration of the copy.
        // The result is load-bearing and must not be discarded: if creation fails
        // (ENOSPC, EDQUOT, EACCES) we must not fall through to opening the path
        // read-write, because SQLite would then create the file at the umask
        // default (0644) and the backup below would write the entire dictation
        // history into it before the re-assert on line 60 gets a chance to run.
        guard
            FileManager.default.createFile(
                atPath: destination.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        else {
            throw DatabaseError.cantOpen("could not create snapshot file")
        }

        do {
            // Both handles are scoped so they close on every exit path.
            let reader = try Database(path: source.path, readOnly: true)
            let writer = try Database(path: destination.path, readOnly: false)
            try reader.backup(to: writer)
            // Without this the copy stays in WAL mode and a read-only open fails.
            try writer.clearJournalModeForSnapshot()
        } catch {
            discard(destination)
            throw error
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
        return destination
    }

    /// Deletes a snapshot. Called from a `defer` so it happens on the error path too.
    ///
    /// SQLite can leave `-shm` and `-wal` sidecars next to the snapshot; deleting
    /// only the main file would leave page content behind in a directory we
    /// promised would hold no transcript once the ingest returns.
    public static func discard(_ url: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        for suffix in ["-shm", "-wal"] {
            try? manager.removeItem(atPath: url.path + suffix)
        }
    }

    /// Removes snapshots orphaned by a crash, force-quit or logout.
    ///
    /// Without this, anything the OS did not clean up would persist indefinitely
    /// in a cache directory, accumulating copies of dictation history.
    /// Returns how many were removed so a recurring crash stays visible.
    @discardableResult
    public static func sweep(directory: URL) -> Int {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            return 0
        }
        var removed = 0
        for name in names where name.hasPrefix(prefix) {
            discard(directory.appendingPathComponent(name))
            removed += 1
        }
        return removed
    }
}
