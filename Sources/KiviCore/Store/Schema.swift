import Foundation

/// Our own schema. Numbers only.
///
/// The hard rule: no column in this schema can hold transcript text. There is a
/// test that fails if a column named like text/transcript/raw/formatted/body
/// ever appears, because that invariant is the product's privacy promise.
public enum Schema {
    public static let version = 1

    /// Statements are applied one at a time — `sqlite3_prepare_v2` handles a
    /// single statement, so this is an array rather than one script.
    static let statements: [String] = [
        // Must precede the first table: it cannot be changed afterwards.
        "PRAGMA auto_vacuum=INCREMENTAL",
        "PRAGMA journal_mode=WAL",
        "PRAGMA foreign_keys=ON",
        """
        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS source_store (
            source_id           INTEGER PRIMARY KEY,
            kivi_installation_id TEXT,
            store_path           TEXT NOT NULL,
            kivi_app_version     TEXT,
            kivi_model_version   TEXT,
            schema_hash          TEXT NOT NULL,
            max_pk_seen          INTEGER NOT NULL DEFAULT 0,
            first_seen_at        INTEGER NOT NULL,
            last_ingest_at       INTEGER
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS ingest_run (
            run_id             INTEGER PRIMARY KEY,
            started_at         INTEGER NOT NULL,
            finished_at        INTEGER,
            outcome            TEXT NOT NULL,
            detail             TEXT,
            rows_seen          INTEGER NOT NULL DEFAULT 0,
            rows_new           INTEGER NOT NULL DEFAULT 0,
            rows_retired       INTEGER NOT NULL DEFAULT 0,
            days_rebuilt       INTEGER NOT NULL DEFAULT 0,
            duration_ms        INTEGER NOT NULL DEFAULT 0,
            incognito_at_run   INTEGER,
            take_success_at_run INTEGER
        ) STRICT
        """,
        // The system of record. Never pruned.
        """
        CREATE TABLE IF NOT EXISTS take (
            source_id      INTEGER NOT NULL,
            kivi_pk        INTEGER NOT NULL,
            taken_at       INTEGER NOT NULL,
            day_local      TEXT NOT NULL,
            hour_local     INTEGER NOT NULL,
            mode           TEXT NOT NULL,
            bundle_id      TEXT,
            bundle_key     TEXT,
            duration_ms    INTEGER,
            word_count     INTEGER NOT NULL,
            char_count     INTEGER NOT NULL,
            word_method    TEXT NOT NULL,
            is_complete    INTEGER NOT NULL,
            speed_eligible INTEGER NOT NULL,
            src_updated_at INTEGER NOT NULL,
            ingested_at    INTEGER NOT NULL,
            last_seen_run  INTEGER NOT NULL,
            retired_at     INTEGER,
            PRIMARY KEY (source_id, kivi_pk)
        ) WITHOUT ROWID
        """,
        "CREATE INDEX IF NOT EXISTS ix_take_dayhour ON take(day_local, hour_local)",
        "CREATE INDEX IF NOT EXISTS ix_take_appday ON take(bundle_key, day_local)",
        "CREATE INDEX IF NOT EXISTS ix_take_seen ON take(source_id, last_seen_run)",
        // The UI reads only these two.
        """
        CREATE TABLE IF NOT EXISTS daily_rollup (
            day_local       TEXT NOT NULL,
            source_id       INTEGER NOT NULL,
            takes_dictate   INTEGER NOT NULL DEFAULT 0,
            takes_clipboard INTEGER NOT NULL DEFAULT 0,
            words           INTEGER NOT NULL DEFAULT 0,
            words_dictate   INTEGER NOT NULL DEFAULT 0,
            char_count      INTEGER NOT NULL DEFAULT 0,
            mic_ms          INTEGER NOT NULL DEFAULT 0,
            speech_ms       INTEGER NOT NULL DEFAULT 0,
            speech_words    INTEGER NOT NULL DEFAULT 0,
            takes_live      INTEGER NOT NULL DEFAULT 0,
            takes_retired   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day_local, source_id)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS daily_app_rollup (
            day_local    TEXT NOT NULL,
            source_id    INTEGER NOT NULL,
            bundle_key   TEXT NOT NULL,
            bundle_id    TEXT,
            takes        INTEGER NOT NULL DEFAULT 0,
            words        INTEGER NOT NULL DEFAULT 0,
            takes_dictate INTEGER NOT NULL DEFAULT 0,
            words_dictate INTEGER NOT NULL DEFAULT 0,
            mic_ms       INTEGER NOT NULL DEFAULT 0,
            speech_ms    INTEGER NOT NULL DEFAULT 0,
            speech_words INTEGER NOT NULL DEFAULT 0,
            last_seen_at INTEGER,
            PRIMARY KEY (day_local, source_id, bundle_key)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS counter_sample (
            source_id      INTEGER NOT NULL,
            taken_at       INTEGER NOT NULL,
            install_id     TEXT,
            generation     INTEGER NOT NULL,
            take_started   INTEGER,
            take_success   INTEGER,
            take_cancelled INTEGER,
            take_fail_empty INTEGER,
            paste_verified INTEGER,
            incognito_now  INTEGER
        ) STRICT
        """,
        "CREATE INDEX IF NOT EXISTS ix_counter_sample ON counter_sample(source_id, taken_at DESC)",
        """
        CREATE TABLE IF NOT EXISTS coverage_generation (
            source_id     INTEGER NOT NULL,
            generation    INTEGER NOT NULL,
            install_id    TEXT,
            started_at    INTEGER NOT NULL,
            ended_at      INTEGER,
            base_started  INTEGER NOT NULL DEFAULT 0,
            base_success  INTEGER NOT NULL DEFAULT 0,
            base_ingested INTEGER NOT NULL DEFAULT 0,
            reset_reason  TEXT,
            PRIMARY KEY (source_id, generation)
        ) STRICT
        """,
    ]

    /// Columns whose presence would break the privacy promise.
    static let forbiddenColumnNames: Set<String> = [
        "text", "transcript", "raw", "rawtext", "formatted", "formattedtext",
        "body", "content", "transcription", "prompt",
    ]

    /// Columns added after v1. Applied defensively so an existing database is
    /// upgraded rather than silently missing a column.
    ///
    /// `daily_app_rollup` carries both an all-modes `words`/`takes` and a
    /// dictation-only `words_dictate`/`takes_dictate`. The headline figure is
    /// dictation-only, so the per-app split has to offer the same basis —
    /// otherwise the list under the headline sums to a different number than the
    /// headline itself, which reads as a bug to anyone who adds it up.
    private static let laterAdditions: [(table: String, column: String, statement: String)] = [
        (
            "daily_rollup", "words_dictate",
            "ALTER TABLE daily_rollup ADD COLUMN words_dictate INTEGER NOT NULL DEFAULT 0"
        ),
        (
            "daily_app_rollup", "words_dictate",
            "ALTER TABLE daily_app_rollup ADD COLUMN words_dictate INTEGER NOT NULL DEFAULT 0"
        ),
        (
            "daily_app_rollup", "takes_dictate",
            "ALTER TABLE daily_app_rollup ADD COLUMN takes_dictate INTEGER NOT NULL DEFAULT 0"
        ),
    ]

    /// Set when a column has just been added to a populated rollup table.
    ///
    /// A newly added column defaults to 0, so existing rollup rows would keep
    /// reporting zero for it until their day happened to change upstream — which
    /// for a rarely-changing day may be never. This flag makes the next ingest
    /// rebuild every day instead.
    public static let rebuildFlagKey = "rollup_rebuild_required"

    public static func apply(to db: Database) throws {
        for statement in statements {
            try db.execute(statement)
        }
        for addition in laterAdditions {
            // Table and column names are compile-time constants from the list
            // above, not user input, so interpolating them here is safe.
            let exists =
                try db.scalarInt64(
                    "SELECT count(*) FROM pragma_table_info('\(addition.table)')"
                        + " WHERE name = '\(addition.column)'"
                ) ?? 0
            if exists == 0 {
                try db.execute(addition.statement)
                try db.execute(
                    "INSERT INTO meta (key, value) VALUES ('\(rebuildFlagKey)', '1')"
                        + " ON CONFLICT(key) DO UPDATE SET value = '1'"
                )
            }
        }
        let current = try db.scalarInt64("PRAGMA user_version") ?? 0
        if current < Int64(version) {
            try db.execute("PRAGMA user_version=\(version)")
        }
    }
}
