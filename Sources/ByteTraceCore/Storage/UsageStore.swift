import Foundation
import SQLite3

public final class UsageStore: @unchecked Sendable {
    public static let schemaVersion: Int64 = 3

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

    public func apply(
        _ aggregates: [DailyUsageAggregate],
        bucketAggregates: [UsageBucketAggregate] = []
    ) throws {
        guard !aggregates.isEmpty || !bucketAggregates.isEmpty else { return }

        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for aggregate in aggregates {
                try upsertApp(for: aggregate)
                try upsertDailyUsage(for: aggregate)
            }
            for aggregate in bucketAggregates {
                try upsertApp(for: aggregate)
                try upsertBucketUsage(for: aggregate)
            }
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    public func applyHostUsage(_ records: [NettopHostUsageRecord]) throws {
        guard !records.isEmpty else { return }

        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for record in records {
                try upsertHostUsage(record)
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
        try dailyUsage(from: day, through: day)
    }

    public func dailyUsage(
        from startDay: String,
        through endDay: String
    ) throws -> [DailyUsageRecord] {
        let statement = try database.prepare(
            """
            SELECT d.day, d.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   d.download_bytes, d.upload_bytes, d.sample_count
            FROM daily_usage AS d
            JOIN apps AS a ON a.app_key = d.app_key
            WHERE d.day >= ? AND d.day <= ?
            ORDER BY d.day ASC, (d.download_bytes + d.upload_bytes) DESC,
                     d.app_key ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(startDay, at: 1, in: statement)
        try database.bind(endDay, at: 2, in: statement)

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
                    day: database.columnString(statement, at: 0) ?? startDay,
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

    public func bucketUsage(from start: Date, to end: Date) throws -> [UsageBucketRecord] {
        let statement = try database.prepare(
            """
            SELECT b.bucket_start, b.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   b.download_bytes, b.upload_bytes, b.sample_count
            FROM usage_buckets AS b
            JOIN apps AS a ON a.app_key = b.app_key
            WHERE b.bucket_start >= ? AND b.bucket_start < ?
            ORDER BY b.bucket_start ASC, (b.download_bytes + b.upload_bytes) DESC,
                     b.app_key ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(Self.epochSeconds(start), at: 1, in: statement)
        try database.bind(Self.epochSeconds(end), at: 2, in: statement)

        var records: [UsageBucketRecord] = []
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
                UsageBucketRecord(
                    bucketStart: Date(
                        timeIntervalSince1970: TimeInterval(
                            sqlite3_column_int64(statement, 0)
                        )
                    ),
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

    public func hostUsage(
        from start: Date,
        to end: Date,
        appKey: String? = nil
    ) throws -> [NettopHostUsageRecord] {
        let statement: OpaquePointer
        if appKey != nil {
            statement = try database.prepare(
                """
                SELECT bucket_start, app_key, display_name, endpoint_kind, hostname,
                       first_seen_at, last_seen_at, connection_count,
                       download_bytes, upload_bytes
                FROM host_usage_buckets
                WHERE bucket_start >= ? AND bucket_start < ? AND app_key = ?
                ORDER BY bucket_start ASC,
                         (download_bytes + upload_bytes) DESC,
                         app_key ASC, endpoint_kind ASC, hostname ASC;
                """
            )
        } else {
            statement = try database.prepare(
                """
                SELECT bucket_start, app_key, display_name, endpoint_kind, hostname,
                       first_seen_at, last_seen_at, connection_count,
                       download_bytes, upload_bytes
                FROM host_usage_buckets
                WHERE bucket_start >= ? AND bucket_start < ?
                ORDER BY bucket_start ASC,
                         (download_bytes + upload_bytes) DESC,
                         app_key ASC, endpoint_kind ASC, hostname ASC;
                """
            )
        }
        defer { sqlite3_finalize(statement) }

        try database.bind(Self.epochSeconds(start), at: 1, in: statement)
        try database.bind(Self.epochSeconds(end), at: 2, in: statement)
        if let appKey {
            try database.bind(appKey, at: 3, in: statement)
        }

        var records: [NettopHostUsageRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }

            records.append(
                NettopHostUsageRecord(
                    bucketStart: Date(
                        timeIntervalSince1970: TimeInterval(
                            sqlite3_column_int64(statement, 0)
                        )
                    ),
                    appKey: Self.optionalValue(
                        database.columnString(statement, at: 1)
                    ),
                    displayName: database.columnString(statement, at: 2),
                    endpointKind: NettopEndpointKind(
                        rawValue: database.columnString(statement, at: 3) ?? ""
                    ) ?? .unknown,
                    hostname: Self.optionalValue(
                        database.columnString(statement, at: 4)
                    ),
                    firstSampleAt: Self.dateValue(
                        database.columnString(statement, at: 5)
                    ),
                    lastSampleAt: Self.dateValue(
                        database.columnString(statement, at: 6)
                    ),
                    connectionCount: sqlite3_column_int64(statement, 7),
                    downloadBytes: sqlite3_column_int64(statement, 8),
                    uploadBytes: sqlite3_column_int64(statement, 9)
                )
            )
        }
        return records
    }

    public func clearHostUsage() throws {
        try database.execute("DELETE FROM host_usage_buckets;")
    }

    public func bucketStats() throws -> UsageBucketStats {
        let statement = try database.prepare(
            "SELECT COUNT(*), MIN(bucket_start), MAX(bucket_start) FROM usage_buckets;"
        )
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteDatabaseError.stepFailed(database.errorMessage)
        }

        let earliest = sqlite3_column_type(statement, 1) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
        let latest = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 2)))

        return UsageBucketStats(
            bucketCount: sqlite3_column_int64(statement, 0),
            earliestBucket: earliest,
            latestBucket: latest
        )
    }

    public func purgeBuckets(before date: Date) throws -> Int64 {
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let usageDeleted = try deleteBuckets(
                from: "usage_buckets",
                before: date
            )
            let hostDeleted = try deleteBuckets(
                from: "host_usage_buckets",
                before: date
            )
            try database.execute("COMMIT;")
            let result = usageDeleted.addingReportingOverflow(hostDeleted)
            return result.overflow ? Int64.max : result.partialValue
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    /// 按时间清理诊断事件表（occurred_at 是定宽零填充文本时间戳，字典序等于数值序）。
    public func purgeCollectorEvents(before date: Date) throws -> Int64 {
        let statement = try database.prepare(
            "DELETE FROM collector_events WHERE occurred_at < ?;"
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(Self.timestamp(date), at: 1, in: statement)
        try database.stepDone(statement)
        return database.changes()
    }

    /// WAL 下 DELETE 不收缩文件；大量删除后按需调用。阻塞操作，勿在主线程执行。
    public func vacuum() throws {
        try database.execute("VACUUM;")
    }

    public func clearAll() throws {
        try clearHostUsage()
        try database.execute("DELETE FROM usage_buckets;")
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

        if currentVersion == 0 {
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

        if currentVersion <= 1 {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS usage_buckets (
                    bucket_start INTEGER NOT NULL,
                    app_key TEXT NOT NULL,
                    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                    sample_count INTEGER NOT NULL DEFAULT 0 CHECK (sample_count >= 0),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (bucket_start, app_key),
                    FOREIGN KEY (app_key) REFERENCES apps(app_key)
                );

                CREATE INDEX IF NOT EXISTS idx_usage_buckets_start
                    ON usage_buckets(bucket_start);

                PRAGMA user_version = 2;
                """
            )
        }

        if currentVersion <= 2 {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS host_usage_buckets (
                    bucket_start INTEGER NOT NULL,
                    app_key TEXT NOT NULL DEFAULT '',
                    display_name TEXT,
                    endpoint_kind TEXT NOT NULL,
                    hostname TEXT NOT NULL DEFAULT '',
                    first_seen_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL,
                    connection_count INTEGER NOT NULL DEFAULT 0 CHECK (connection_count >= 0),
                    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                    PRIMARY KEY (bucket_start, app_key, endpoint_kind, hostname)
                );

                CREATE INDEX IF NOT EXISTS idx_host_usage_buckets_start
                    ON host_usage_buckets(bucket_start);

                CREATE INDEX IF NOT EXISTS idx_host_usage_buckets_app_start
                    ON host_usage_buckets(app_key, bucket_start);

                PRAGMA user_version = 3;
                """
            )
        }
    }

    private func upsertApp(for aggregate: DailyUsageAggregate) throws {
        try upsertApp(
            appKey: aggregate.appKey,
            displayName: aggregate.displayName,
            category: aggregate.category,
            bundleID: aggregate.bundleID,
            bundlePath: aggregate.bundlePath,
            executablePath: aggregate.executablePath,
            firstSeenAt: aggregate.firstSeenAt,
            lastSeenAt: aggregate.lastSeenAt
        )
    }

    private func upsertApp(for aggregate: UsageBucketAggregate) throws {
        try upsertApp(
            appKey: aggregate.appKey,
            displayName: aggregate.displayName,
            category: aggregate.category,
            bundleID: aggregate.bundleID,
            bundlePath: aggregate.bundlePath,
            executablePath: aggregate.executablePath,
            firstSeenAt: aggregate.firstSeenAt,
            lastSeenAt: aggregate.lastSeenAt
        )
    }

    private func upsertApp(
        appKey: String,
        displayName: String,
        category: AppCategory,
        bundleID: String?,
        bundlePath: String?,
        executablePath: String?,
        firstSeenAt: Date,
        lastSeenAt: Date
    ) throws {
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

        try database.bind(appKey, at: 1, in: statement)
        try database.bind(bundleID, at: 2, in: statement)
        try database.bind(bundlePath, at: 3, in: statement)
        try database.bind(executablePath, at: 4, in: statement)
        try database.bind(displayName, at: 5, in: statement)
        try database.bind(category.rawValue, at: 6, in: statement)
        try database.bind(Self.timestamp(firstSeenAt), at: 7, in: statement)
        try database.bind(Self.timestamp(lastSeenAt), at: 8, in: statement)
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

    private func upsertBucketUsage(for aggregate: UsageBucketAggregate) throws {
        let statement = try database.prepare(
            """
            INSERT INTO usage_buckets (
                bucket_start, app_key, download_bytes, upload_bytes,
                sample_count, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(bucket_start, app_key) DO UPDATE SET
                download_bytes = usage_buckets.download_bytes + excluded.download_bytes,
                upload_bytes = usage_buckets.upload_bytes + excluded.upload_bytes,
                sample_count = usage_buckets.sample_count + excluded.sample_count,
                updated_at = excluded.updated_at;
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(Self.epochSeconds(aggregate.bucketStart), at: 1, in: statement)
        try database.bind(aggregate.appKey, at: 2, in: statement)
        try database.bind(aggregate.downloadBytes, at: 3, in: statement)
        try database.bind(aggregate.uploadBytes, at: 4, in: statement)
        try database.bind(aggregate.sampleCount, at: 5, in: statement)
        try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 6, in: statement)
        try database.stepDone(statement)
    }

    private func upsertHostUsage(_ record: NettopHostUsageRecord) throws {
        let statement = try database.prepare(
            """
            INSERT INTO host_usage_buckets (
                bucket_start, app_key, display_name, endpoint_kind, hostname,
                first_seen_at, last_seen_at, connection_count,
                download_bytes, upload_bytes
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bucket_start, app_key, endpoint_kind, hostname) DO UPDATE SET
                display_name = excluded.display_name,
                first_seen_at = MIN(host_usage_buckets.first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(host_usage_buckets.last_seen_at, excluded.last_seen_at),
                connection_count = host_usage_buckets.connection_count + excluded.connection_count,
                download_bytes = host_usage_buckets.download_bytes + excluded.download_bytes,
                upload_bytes = host_usage_buckets.upload_bytes + excluded.upload_bytes;
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(Self.epochSeconds(record.bucketStart), at: 1, in: statement)
        try database.bind(Self.storageValue(record.appKey), at: 2, in: statement)
        try database.bind(record.displayName, at: 3, in: statement)
        try database.bind(record.endpointKind.rawValue, at: 4, in: statement)
        try database.bind(Self.storageValue(record.hostname), at: 5, in: statement)
        try database.bind(Self.timestamp(record.firstSampleAt), at: 6, in: statement)
        try database.bind(Self.timestamp(record.lastSampleAt), at: 7, in: statement)
        try database.bind(record.connectionCount, at: 8, in: statement)
        try database.bind(record.downloadBytes, at: 9, in: statement)
        try database.bind(record.uploadBytes, at: 10, in: statement)
        try database.stepDone(statement)
    }

    private func deleteBuckets(from table: String, before date: Date) throws -> Int64 {
        let statement = try database.prepare(
            "DELETE FROM \(table) WHERE bucket_start < ?;"
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(Self.epochSeconds(date), at: 1, in: statement)
        try database.stepDone(statement)
        return database.changes()
    }

    private static func timestamp(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }

    private static func epochSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private static func storageValue(_ value: String?) -> String {
        value ?? ""
    }

    private static func optionalValue(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func dateValue(_ value: String?) -> Date {
        guard let value, let seconds = Double(value) else { return .distantPast }
        return Date(timeIntervalSince1970: seconds)
    }
}
