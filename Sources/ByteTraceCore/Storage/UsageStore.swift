import Foundation
import SQLite3

public final class UsageStore: @unchecked Sendable {
    public static let schemaVersion: Int64 = 1

    private let database: SQLiteDatabase

    public init(databaseURL: URL) throws {
        database = try SQLiteDatabase(url: databaseURL)
        try migrate()
    }

    public static func defaultDatabaseURL(bundleIdentifier: String) -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("usage.sqlite3")
    }

    public func apply(_ aggregates: [DailyUsageAggregate]) throws {
        guard !aggregates.isEmpty else { return }

        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for aggregate in aggregates {
                try upsertApp(for: aggregate)
                try upsertDailyUsage(for: aggregate)
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    public func recordCollectorEvent(
        kind: String,
        occurredAt: Date = Date(),
        details: String? = nil
    ) throws {
        let statement = try database.prepare(
            "INSERT INTO collector_events (occurred_at, kind, details) VALUES (?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(Self.timestamp(occurredAt), at: 1, in: statement)
        try database.bind(kind, at: 2, in: statement)
        try database.bind(details, at: 3, in: statement)
        try database.stepDone(statement)
    }

    public func dailyUsage(for day: String) throws -> [DailyUsageRecord] {
        let statement = try database.prepare(
            """
            SELECT d.day, d.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   d.download_bytes, d.upload_bytes, d.sample_count
            FROM daily_usage AS d
            JOIN apps AS a ON a.app_key = d.app_key
            WHERE d.day = ?
            ORDER BY (d.download_bytes + d.upload_bytes) DESC, d.app_key ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(day, at: 1, in: statement)

        var records: [DailyUsageRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }

            let category = AppCategory(
                rawValue: database.columnString(statement, at: 3) ?? ""
            ) ?? .unclassified
            records.append(
                DailyUsageRecord(
                    day: database.columnString(statement, at: 0) ?? day,
                    appKey: database.columnString(statement, at: 1) ?? "",
                    displayName: database.columnString(statement, at: 2) ?? "未知进程",
                    category: category,
                    bundleID: database.columnString(statement, at: 4),
                    bundlePath: database.columnString(statement, at: 5),
                    executablePath: database.columnString(statement, at: 6),
                    downloadBytes: sqlite3_column_int64(statement, 7),
                    uploadBytes: sqlite3_column_int64(statement, 8),
                    sampleCount: sqlite3_column_int64(statement, 9)
                )
            )
        }
        return records
    }

    public func clearAll() throws {
        try database.execute("DELETE FROM daily_usage;")
        try database.execute("DELETE FROM apps;")
        try database.execute("DELETE FROM collector_events;")
    }

    private func migrate() throws {
        let currentVersion = try database.scalarInt64("PRAGMA user_version;")
        guard currentVersion <= Self.schemaVersion else {
            throw SQLiteDatabaseError.executeFailed(
                "unsupported schema version \(currentVersion)"
            )
        }
        guard currentVersion == 0 else { return }

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS apps (
                app_key TEXT PRIMARY KEY,
                bundle_id TEXT,
                bundle_path TEXT,
                executable_path TEXT,
                display_name TEXT NOT NULL,
                category TEXT NOT NULL,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS daily_usage (
                day TEXT NOT NULL,
                app_key TEXT NOT NULL,
                download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                sample_count INTEGER NOT NULL DEFAULT 0 CHECK (sample_count >= 0),
                updated_at TEXT NOT NULL,
                PRIMARY KEY (day, app_key),
                FOREIGN KEY (app_key) REFERENCES apps(app_key)
            );

            CREATE TABLE IF NOT EXISTS collector_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                occurred_at TEXT NOT NULL,
                kind TEXT NOT NULL,
                details TEXT
            );

            PRAGMA user_version = 1;
            """
        )
    }

    private func upsertApp(for aggregate: DailyUsageAggregate) throws {
        let statement = try database.prepare(
            """
            INSERT INTO apps (
                app_key, bundle_id, bundle_path, executable_path,
                display_name, category, first_seen_at, last_seen_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(app_key) DO UPDATE SET
                bundle_id = excluded.bundle_id,
                bundle_path = excluded.bundle_path,
                executable_path = excluded.executable_path,
                display_name = excluded.display_name,
                category = excluded.category,
                last_seen_at = excluded.last_seen_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(aggregate.appKey, at: 1, in: statement)
        try database.bind(aggregate.bundleID, at: 2, in: statement)
        try database.bind(aggregate.bundlePath, at: 3, in: statement)
        try database.bind(aggregate.executablePath, at: 4, in: statement)
        try database.bind(aggregate.displayName, at: 5, in: statement)
        try database.bind(aggregate.category.rawValue, at: 6, in: statement)
        try database.bind(Self.timestamp(aggregate.firstSeenAt), at: 7, in: statement)
        try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 8, in: statement)
        try database.stepDone(statement)
    }

    private func upsertDailyUsage(for aggregate: DailyUsageAggregate) throws {
        let statement = try database.prepare(
            """
            INSERT INTO daily_usage (
                day, app_key, download_bytes, upload_bytes, sample_count, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(day, app_key) DO UPDATE SET
                download_bytes = daily_usage.download_bytes + excluded.download_bytes,
                upload_bytes = daily_usage.upload_bytes + excluded.upload_bytes,
                sample_count = daily_usage.sample_count + excluded.sample_count,
                updated_at = excluded.updated_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(aggregate.day, at: 1, in: statement)
        try database.bind(aggregate.appKey, at: 2, in: statement)
        try database.bind(aggregate.downloadBytes, at: 3, in: statement)
        try database.bind(aggregate.uploadBytes, at: 4, in: statement)
        try database.bind(aggregate.sampleCount, at: 5, in: statement)
        try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 6, in: statement)
        try database.stepDone(statement)
    }

    private static func timestamp(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }
}
