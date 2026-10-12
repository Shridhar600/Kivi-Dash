import Foundation

/// Every filesystem location the app touches, in one place.
///
/// `home` is injectable so tests never read or write the real user's home
/// directory.
public struct AppPaths: Sendable {
    /// Reverse-DNS id for our own app. Used for the Application Support folder.
    ///
    /// Deliberately not under Sarvam's `ai.sarvam.*` namespace: this app is not
    /// theirs, and its data directory is ours.
    public static let bundleIdentifier = "com.shridhar600.kividash"

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Our database — the system of record for numbers. Lives in Application
    /// Support so Time Machine backs it up: losing it loses history that Kivi
    /// has already deleted.
    public var database: URL {
        home
            .appendingPathComponent("Library/Application Support/\(Self.bundleIdentifier)", isDirectory: true)
            .appendingPathComponent("kivi-stats.sqlite3")
    }

    /// Snapshots live in Caches because they are disposable and are the only
    /// artefact that ever contains transcript text.
    public var snapshotDirectory: URL {
        home.appendingPathComponent("Library/Caches/\(Self.bundleIdentifier)", isDirectory: true)
    }

    public var applicationSupportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/\(Self.bundleIdentifier)", isDirectory: true)
    }

    /// Creates the directories we need, and the database's parent.
    ///
    /// The mode is re-asserted after creation because `createDirectory` silently
    /// does *not* tighten an existing directory. Without this, a directory left
    /// behind by an older build — or created by hand while troubleshooting —
    /// stays group- or world-readable, and since the database file itself is
    /// created by SQLite at the umask default (0644), every bundle id you have
    /// dictated into becomes readable by any other local account.
    public func prepareDirectories() throws {
        for directory in [applicationSupportDirectory, snapshotDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    /// Restricts our own database and its WAL sidecars to the owning user.
    ///
    /// SQLite creates them at `0666 & ~umask`, so without this they are 0644 on a
    /// stock macOS. The 0700 parent directory is the real protection; this is the
    /// second layer, and it matters if the database is ever copied, restored from
    /// a backup that did not preserve modes, or opened through a path that does
    /// not go through `prepareDirectories`.
    public func secureDatabasePermissions() {
        let paths = [
            database.path,
            database.path + "-wal",
            database.path + "-shm",
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        }
    }

    /// Kivi's store, in its Application Support directory.
    ///
    /// Globs rather than hardcoding a name, because Kivi could move the file and
    /// we must never bind to a copy of our own database instead. Candidates are
    /// filtered by suffix (so `-wal`/`-shm` siblings are excluded without also
    /// rejecting a legitimate name containing a hyphen) and directories are
    /// skipped.
    ///
    /// Among the candidates we prefer one that actually contains a `ZCAPTURE`
    /// table. Picking the alphabetically-first `*.store` would silently bind this
    /// app to some *other* app's database, which then fails the schema contract
    /// forever with no hint that the wrong file was chosen.
    public func locateSourceStore(
        in appSupport: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory =
            appSupport
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)

        let names = try fileManager.contentsOfDirectory(atPath: directory.path)
        let candidates =
            names.filter { name in
                guard name.hasSuffix(".store") else { return false }
                // SQLite honours a `file:` URI filename even without
                // SQLITE_OPEN_URI, and a `?mode=rwc` parameter would override the
                // read-only flag we pass to sqlite3_open_v2 — silently defeating
                // the guarantee that we never open the source writable.
                guard !name.hasPrefix("file:"), !name.contains("?") else { return false }
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(
                    atPath: directory.appendingPathComponent(name).path,
                    isDirectory: &isDirectory
                )
                return exists && !isDirectory.boolValue
            }
            .sorted()

        guard !candidates.isEmpty else {
            throw SourceNotFound(directory: directory)
        }

        for name in candidates {
            let url = directory.appendingPathComponent(name)
            // Parenthesised deliberately: `??` binds tighter than `>`, so this is
            // already `(nil ?? 0) > 0`. See the same note in Ingestor.
            let captureTables =
                (try? Database(path: url.path, readOnly: true))
                .flatMap { db in
                    try? db.scalarInt64(
                        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='ZCAPTURE'"
                    )
                } ?? 0
            if captureTables > 0 {
                return url
            }
        }
        // Fall back to the first so the caller can produce a proper schema-drift
        // diagnostic rather than "not found".
        return directory.appendingPathComponent(candidates[0])
    }
}

public struct SourceNotFound: Error, CustomStringConvertible, Sendable {
    public let directory: URL
    public var description: String {
        "No Kivi store (*.store) found in \(directory.path)"
    }
}
