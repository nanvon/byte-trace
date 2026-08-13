import Foundation
import SQLite3

public final class UsageStore: @unchecked Sendable {
    public static let schemaVersion: Int64 = 6
    public static let accountingVersion: Int64 = 3

    private let database: SQLiteDatabase
    /// 保护整个数据库连接：单个 sqlite3 句柄会被主线程（落库、查询）与后台队列
    /// （保留策略的 purge / VACUUM）同时使用。`apply` 与 `purgeBuckets` 各自是
    /// `BEGIN IMMEDIATE … COMMIT` 的多语句事务，光靠 SQLite 自身的串行化不够——
    /// 两边并发会撞上 "cannot start a transaction within a transaction"，
    /// 落库因此失败（数据留在聚合器里等下次重试，但会持续报错）。
    /// 锁必须加在事务边界这一层，不能下沉到 SQLiteDatabase 的单条语句上。
    /// 用可重入锁：`dailyUsage(for:)` 会转调 `dailyUsage(from:through:)`。
    private let lock = NSRecursiveLock()
    private static let legacyCCBarAppKey = "proxy:ccbar"

    private struct StoredApp {
        let bundleID: String?
        let bundlePath: String?
        let executablePath: String?
        let displayName: String
        let firstSeenAt: String
        let lastSeenAt: String
    }

    /// One app row per appKey for a whole flush. Daily and bucket aggregates
    /// carry the same attribution metadata, so writing the app once avoids a
    /// duplicate UPSERT without changing usage accounting.
    private struct AppAggregate {
        let appKey: String
        let displayName: String
        let category: AppCategory
        let bundleID: String?
        let bundlePath: String?
        let executablePath: String?
        let firstSeenAt: Date
        let lastSeenAt: Date

        init(_ aggregate: DailyUsageAggregate) {
            appKey = aggregate.appKey
            displayName = aggregate.displayName
            category = aggregate.category
            bundleID = aggregate.bundleID
            bundlePath = aggregate.bundlePath
            executablePath = aggregate.executablePath
            firstSeenAt = aggregate.firstSeenAt
            lastSeenAt = aggregate.lastSeenAt
        }

        init(_ aggregate: UsageBucketAggregate) {
            appKey = aggregate.appKey
            displayName = aggregate.displayName
            category = aggregate.category
            bundleID = aggregate.bundleID
            bundlePath = aggregate.bundlePath
            executablePath = aggregate.executablePath
            firstSeenAt = aggregate.firstSeenAt
            lastSeenAt = aggregate.lastSeenAt
        }

        init(
            appKey: String,
            displayName: String,
            category: AppCategory,
            bundleID: String?,
            bundlePath: String?,
            executablePath: String?,
            firstSeenAt: Date,
            lastSeenAt: Date
        ) {
            self.appKey = appKey
            self.displayName = displayName
            self.category = category
            self.bundleID = bundleID
            self.bundlePath = bundlePath
            self.executablePath = executablePath
            self.firstSeenAt = firstSeenAt
            self.lastSeenAt = lastSeenAt
        }

        func merging(_ candidate: AppAggregate) -> AppAggregate {
            let latest = candidate.lastSeenAt >= lastSeenAt ? candidate : self
            return AppAggregate(
                appKey: appKey,
                displayName: latest.displayName,
                category: latest.category,
                bundleID: latest.bundleID,
                bundlePath: latest.bundlePath,
                executablePath: latest.executablePath,
                firstSeenAt: min(firstSeenAt, candidate.firstSeenAt),
                lastSeenAt: max(lastSeenAt, candidate.lastSeenAt)
            )
        }
    }

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

        lock.lock()
        defer { lock.unlock() }
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let appStatement = try prepareAppUpsert()
            defer { sqlite3_finalize(appStatement) }
            let dailyStatement = try prepareDailyUsageUpsert()
            defer { sqlite3_finalize(dailyStatement) }
            let bucketStatement = try prepareBucketUsageUpsert()
            defer { sqlite3_finalize(bucketStatement) }

            var apps: [String: AppAggregate] = [:]
            for aggregate in aggregates {
                mergeApp(AppAggregate(aggregate), into: &apps)
            }
            for aggregate in bucketAggregates {
                mergeApp(AppAggregate(aggregate), into: &apps)
            }

            for app in apps.values {
                try upsertApp(app, using: appStatement)
            }
            for aggregate in aggregates {
                try upsertDailyUsage(aggregate, using: dailyStatement)
            }
            for aggregate in bucketAggregates {
                try upsertBucketUsage(aggregate, using: bucketStatement)
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
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        return try dailyUsage(from: day, through: day)
    }

    public func dailyUsage(
        from startDay: String,
        through endDay: String
    ) throws -> [DailyUsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try database.prepare(
            """
            SELECT d.day, d.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   d.download_bytes, d.upload_bytes, d.sample_count
            FROM daily_usage AS d
            JOIN apps AS a ON a.app_key = d.app_key
            WHERE d.accounting_version = ? AND d.day >= ? AND d.day <= ?
            ORDER BY d.day ASC, (d.download_bytes + d.upload_bytes) DESC,
                     d.app_key ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(Self.accountingVersion, at: 1, in: statement)
        try database.bind(startDay, at: 2, in: statement)
        try database.bind(endDay, at: 3, in: statement)

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
        lock.lock()
        defer { lock.unlock() }
        let statement = try database.prepare(
            """
            SELECT b.bucket_start, b.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   b.download_bytes, b.upload_bytes, b.sample_count
            FROM usage_buckets AS b
            JOIN apps AS a ON a.app_key = b.app_key
            WHERE b.accounting_version = ? AND b.bucket_start >= ? AND b.bucket_start < ?
            ORDER BY b.bucket_start ASC, (b.download_bytes + b.upload_bytes) DESC,
                     b.app_key ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(Self.accountingVersion, at: 1, in: statement)
        try database.bind(Self.epochSeconds(start), at: 2, in: statement)
        try database.bind(Self.epochSeconds(end), at: 3, in: statement)

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

    public func bucketUsageSummary(
        from start: Date,
        to end: Date
    ) throws -> [UsageBucketSummaryRecord] {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try queryBucketUsageSummary(from: start, to: end)
        } catch where Self.isSQLiteIntegerOverflow(error) {
            // SQLite SUM() aborts on integer overflow, while ByteTrace's public
            // accounting contract saturates at Int64.max. Keep the compact SQL
            // path for normal data and preserve the old behavior at the edge.
            return try saturatedBucketUsageSummary(from: start, to: end)
        }
    }

    private func queryBucketUsageSummary(
        from start: Date,
        to end: Date
    ) throws -> [UsageBucketSummaryRecord] {
        let statement = try database.prepare(
            """
            SELECT MIN(b.bucket_start), b.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   SUM(b.download_bytes), SUM(b.upload_bytes), SUM(b.sample_count)
            FROM usage_buckets AS b
            JOIN apps AS a ON a.app_key = b.app_key
            WHERE b.accounting_version = ? AND b.bucket_start >= ? AND b.bucket_start < ?
            GROUP BY b.app_key, a.display_name, a.category,
                     a.bundle_id, a.bundle_path, a.executable_path
            ORDER BY (SUM(b.download_bytes) + SUM(b.upload_bytes)) DESC,
                     b.app_key ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(Self.accountingVersion, at: 1, in: statement)
        try database.bind(Self.epochSeconds(start), at: 2, in: statement)
        try database.bind(Self.epochSeconds(end), at: 3, in: statement)

        var records: [UsageBucketSummaryRecord] = []
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
                UsageBucketSummaryRecord(
                    firstBucketStart: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))
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

    public func bucketTimeline(
        from start: Date,
        to end: Date,
        appKey: String? = nil,
        excludingProxyTransport: Bool = true
    ) throws -> [UsageTimelineRecord] {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try queryBucketTimeline(
                from: start,
                to: end,
                appKey: appKey,
                excludingProxyTransport: excludingProxyTransport
            )
        } catch where Self.isSQLiteIntegerOverflow(error) {
            return try saturatedBucketTimeline(
                from: start,
                to: end,
                appKey: appKey,
                excludingProxyTransport: excludingProxyTransport
            )
        }
    }

    private func queryBucketTimeline(
        from start: Date,
        to end: Date,
        appKey: String?,
        excludingProxyTransport: Bool
    ) throws -> [UsageTimelineRecord] {
        var conditions = [
            "b.accounting_version = ?",
            "b.bucket_start >= ?",
            "b.bucket_start < ?"
        ]
        if appKey != nil {
            conditions.append("b.app_key = ?")
        }
        if excludingProxyTransport {
            conditions.append("a.category != ?")
        }

        let statement = try database.prepare(
            """
            SELECT b.bucket_start, SUM(b.download_bytes), SUM(b.upload_bytes)
            FROM usage_buckets AS b
            JOIN apps AS a ON a.app_key = b.app_key
            WHERE \(conditions.joined(separator: " AND "))
            GROUP BY b.bucket_start
            ORDER BY b.bucket_start ASC;
            """
        )
        defer { sqlite3_finalize(statement) }

        var bindingIndex: Int32 = 1
        try database.bind(Self.accountingVersion, at: bindingIndex, in: statement)
        bindingIndex += 1
        try database.bind(Self.epochSeconds(start), at: bindingIndex, in: statement)
        bindingIndex += 1
        try database.bind(Self.epochSeconds(end), at: bindingIndex, in: statement)
        bindingIndex += 1
        if let appKey {
            try database.bind(appKey, at: bindingIndex, in: statement)
            bindingIndex += 1
        }
        if excludingProxyTransport {
            try database.bind(AppCategory.proxyTransport.rawValue, at: bindingIndex, in: statement)
        }

        var records: [UsageTimelineRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }
            records.append(
                UsageTimelineRecord(
                    bucketStart: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))
                    ),
                    downloadBytes: sqlite3_column_int64(statement, 1),
                    uploadBytes: sqlite3_column_int64(statement, 2)
                )
            )
        }
        return records
    }

    private func saturatedBucketUsageSummary(
        from start: Date,
        to end: Date
    ) throws -> [UsageBucketSummaryRecord] {
        var summaries: [String: UsageBucketSummaryRecord] = [:]
        for record in try bucketUsage(from: start, to: end) {
            if let existing = summaries[record.appKey] {
                summaries[record.appKey] = UsageBucketSummaryRecord(
                    firstBucketStart: min(existing.firstBucketStart, record.bucketStart),
                    appKey: record.appKey,
                    displayName: record.displayName,
                    category: record.category,
                    bundleID: record.bundleID,
                    bundlePath: record.bundlePath,
                    executablePath: record.executablePath,
                    downloadBytes: Self.saturatingAdd(
                        existing.downloadBytes,
                        record.downloadBytes
                    ),
                    uploadBytes: Self.saturatingAdd(
                        existing.uploadBytes,
                        record.uploadBytes
                    ),
                    sampleCount: Self.saturatingAdd(
                        existing.sampleCount,
                        record.sampleCount
                    )
                )
            } else {
                summaries[record.appKey] = UsageBucketSummaryRecord(
                    firstBucketStart: record.bucketStart,
                    appKey: record.appKey,
                    displayName: record.displayName,
                    category: record.category,
                    bundleID: record.bundleID,
                    bundlePath: record.bundlePath,
                    executablePath: record.executablePath,
                    downloadBytes: record.downloadBytes,
                    uploadBytes: record.uploadBytes,
                    sampleCount: record.sampleCount
                )
            }
        }
        return summaries.values.sorted {
            let left = Self.saturatingAdd($0.downloadBytes, $0.uploadBytes)
            let right = Self.saturatingAdd($1.downloadBytes, $1.uploadBytes)
            if left != right { return left > right }
            return $0.appKey < $1.appKey
        }
    }

    private func saturatedBucketTimeline(
        from start: Date,
        to end: Date,
        appKey: String?,
        excludingProxyTransport: Bool
    ) throws -> [UsageTimelineRecord] {
        var totals: [Date: (download: Int64, upload: Int64)] = [:]
        for record in try bucketUsage(from: start, to: end) {
            if let appKey, record.appKey != appKey { continue }
            if excludingProxyTransport, record.category == .proxyTransport { continue }
            let existing = totals[record.bucketStart] ?? (0, 0)
            totals[record.bucketStart] = (
                Self.saturatingAdd(existing.download, record.downloadBytes),
                Self.saturatingAdd(existing.upload, record.uploadBytes)
            )
        }
        return totals.keys.sorted().compactMap { bucketStart in
            guard let total = totals[bucketStart] else { return nil }
            return UsageTimelineRecord(
                bucketStart: bucketStart,
                downloadBytes: total.download,
                uploadBytes: total.upload
            )
        }
    }

    public func bucketStats() throws -> UsageBucketStats {
        lock.lock()
        defer { lock.unlock() }
        let statement = try database.prepare(
            """
            SELECT COUNT(*), MIN(bucket_start), MAX(bucket_start)
            FROM usage_buckets
            WHERE accounting_version = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(Self.accountingVersion, at: 1, in: statement)

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
        lock.lock()
        defer { lock.unlock() }
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let usageDeleted = try deleteBuckets(
                from: "usage_buckets",
                before: date
            )
            try database.execute("COMMIT;")
            return usageDeleted
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    /// 按时间清理诊断事件表（occurred_at 是定宽零填充文本时间戳，字典序等于数值序）。
    public func purgeCollectorEvents(before date: Date) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        try database.execute("VACUUM;")
    }

    public func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
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
                PRAGMA user_version = 3;
                """
            )
        }

        if currentVersion <= 3 {
            try migrateLegacyCCBar()
            try database.execute("PRAGMA user_version = 4;")
        }

        if currentVersion <= 4 {
            try database.execute(
                """
                DROP TABLE IF EXISTS host_usage_buckets;
                PRAGMA user_version = 5;
                """
            )
        }

        if currentVersion <= 5 {
            try migrateAccountingVersion()
        }
    }

    private func migrateAccountingVersion() throws {
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try database.execute(
                """
                CREATE TABLE daily_usage_v6 (
                    accounting_version INTEGER NOT NULL CHECK (accounting_version > 0),
                    day TEXT NOT NULL,
                    app_key TEXT NOT NULL,
                    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                    sample_count INTEGER NOT NULL DEFAULT 0 CHECK (sample_count >= 0),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (accounting_version, day, app_key),
                    FOREIGN KEY (app_key) REFERENCES apps(app_key)
                );

                INSERT INTO daily_usage_v6 (
                    accounting_version, day, app_key, download_bytes,
                    upload_bytes, sample_count, updated_at
                )
                SELECT 1, day, app_key, download_bytes, upload_bytes, sample_count, updated_at
                FROM daily_usage;

                CREATE TABLE usage_buckets_v6 (
                    accounting_version INTEGER NOT NULL CHECK (accounting_version > 0),
                    bucket_start INTEGER NOT NULL,
                    app_key TEXT NOT NULL,
                    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                    sample_count INTEGER NOT NULL DEFAULT 0 CHECK (sample_count >= 0),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (accounting_version, bucket_start, app_key),
                    FOREIGN KEY (app_key) REFERENCES apps(app_key)
                );

                INSERT INTO usage_buckets_v6 (
                    accounting_version, bucket_start, app_key, download_bytes,
                    upload_bytes, sample_count, updated_at
                )
                SELECT 1, bucket_start, app_key, download_bytes, upload_bytes, sample_count, updated_at
                FROM usage_buckets;

                DROP INDEX IF EXISTS idx_usage_buckets_start;
                DROP TABLE daily_usage;
                DROP TABLE usage_buckets;
                ALTER TABLE daily_usage_v6 RENAME TO daily_usage;
                ALTER TABLE usage_buckets_v6 RENAME TO usage_buckets;

                CREATE INDEX idx_usage_buckets_start
                    ON usage_buckets(accounting_version, bucket_start);

                PRAGMA user_version = 6;
                """
            )
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    /// CCBar 曾被错误归类为代理进程；迁移已有数据，保留历史流量并恢复普通应用归属。
    private func migrateLegacyCCBar() throws {
        guard let legacyApp = try storedApp(for: Self.legacyCCBarAppKey),
              let target = targetApp(for: legacyApp),
              target.appKey != Self.legacyCCBarAppKey else {
            return
        }

        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try upsertMigratedApp(
                legacyApp,
                appKey: target.appKey,
                category: target.category
            )
            try mergeLegacyDailyUsage(
                from: Self.legacyCCBarAppKey,
                to: target.appKey
            )
            try mergeLegacyBucketUsage(
                from: Self.legacyCCBarAppKey,
                to: target.appKey
            )
            try deleteAppRows(for: Self.legacyCCBarAppKey)
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    private func storedApp(for appKey: String) throws -> StoredApp? {
        let statement = try database.prepare(
            """
            SELECT bundle_id, bundle_path, executable_path, display_name,
                   first_seen_at, last_seen_at
            FROM apps
            WHERE app_key = ?;
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(appKey, at: 1, in: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw SQLiteDatabaseError.stepFailed(database.errorMessage)
        }

        return StoredApp(
            bundleID: database.columnString(statement, at: 0),
            bundlePath: database.columnString(statement, at: 1),
            executablePath: database.columnString(statement, at: 2),
            displayName: database.columnString(statement, at: 3) ?? "未知进程",
            firstSeenAt: database.columnString(statement, at: 4) ?? "0.000000",
            lastSeenAt: database.columnString(statement, at: 5) ?? "0.000000"
        )
    }

    private func targetApp(for storedApp: StoredApp) -> (appKey: String, category: AppCategory)? {
        if let bundleID = nonEmpty(storedApp.bundleID) {
            return ("bundle:\(bundleID)", .userApp)
        }
        if let bundlePath = nonEmpty(storedApp.bundlePath) {
            return ("app:\(bundlePath)", .userApp)
        }
        if let executablePath = nonEmpty(storedApp.executablePath) {
            return ("exec:\(executablePath)", .unclassified)
        }
        guard let displayName = nonEmpty(storedApp.displayName) else { return nil }
        return ("process:\(displayName)", .unclassified)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func upsertMigratedApp(
        _ storedApp: StoredApp,
        appKey: String,
        category: AppCategory
    ) throws {
        let statement = try database.prepare(
            """
            INSERT INTO apps (
                app_key, bundle_id, bundle_path, executable_path,
                display_name, category, first_seen_at, last_seen_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(app_key) DO UPDATE SET
                bundle_id = COALESCE(excluded.bundle_id, apps.bundle_id),
                bundle_path = COALESCE(excluded.bundle_path, apps.bundle_path),
                executable_path = COALESCE(excluded.executable_path, apps.executable_path),
                display_name = excluded.display_name,
                category = excluded.category,
                first_seen_at = MIN(apps.first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(apps.last_seen_at, excluded.last_seen_at);
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(appKey, at: 1, in: statement)
        try database.bind(storedApp.bundleID, at: 2, in: statement)
        try database.bind(storedApp.bundlePath, at: 3, in: statement)
        try database.bind(storedApp.executablePath, at: 4, in: statement)
        try database.bind(storedApp.displayName, at: 5, in: statement)
        try database.bind(category.rawValue, at: 6, in: statement)
        try database.bind(storedApp.firstSeenAt, at: 7, in: statement)
        try database.bind(storedApp.lastSeenAt, at: 8, in: statement)
        try database.stepDone(statement)
    }

    private func mergeLegacyDailyUsage(from oldAppKey: String, to newAppKey: String) throws {
        let statement = try database.prepare(
            """
            INSERT INTO daily_usage (
                day, app_key, download_bytes, upload_bytes, sample_count, updated_at
            )
            SELECT day, ?, download_bytes, upload_bytes, sample_count, updated_at
            FROM daily_usage
            WHERE app_key = ?
            ON CONFLICT(day, app_key) DO UPDATE SET
                download_bytes = daily_usage.download_bytes + excluded.download_bytes,
                upload_bytes = daily_usage.upload_bytes + excluded.upload_bytes,
                sample_count = daily_usage.sample_count + excluded.sample_count,
                updated_at = MAX(daily_usage.updated_at, excluded.updated_at);
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(newAppKey, at: 1, in: statement)
        try database.bind(oldAppKey, at: 2, in: statement)
        try database.stepDone(statement)
        try deleteRows(in: "daily_usage", for: oldAppKey)
    }

    private func mergeLegacyBucketUsage(from oldAppKey: String, to newAppKey: String) throws {
        let statement = try database.prepare(
            """
            INSERT INTO usage_buckets (
                bucket_start, app_key, download_bytes, upload_bytes,
                sample_count, updated_at
            )
            SELECT bucket_start, ?, download_bytes, upload_bytes, sample_count, updated_at
            FROM usage_buckets
            WHERE app_key = ?
            ON CONFLICT(bucket_start, app_key) DO UPDATE SET
                download_bytes = usage_buckets.download_bytes + excluded.download_bytes,
                upload_bytes = usage_buckets.upload_bytes + excluded.upload_bytes,
                sample_count = usage_buckets.sample_count + excluded.sample_count,
                updated_at = MAX(usage_buckets.updated_at, excluded.updated_at);
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(newAppKey, at: 1, in: statement)
        try database.bind(oldAppKey, at: 2, in: statement)
        try database.stepDone(statement)
        try deleteRows(in: "usage_buckets", for: oldAppKey)
    }

    private func deleteRows(in table: String, for appKey: String) throws {
        let statement = try database.prepare("DELETE FROM \(table) WHERE app_key = ?;")
        defer { sqlite3_finalize(statement) }
        try database.bind(appKey, at: 1, in: statement)
        try database.stepDone(statement)
    }

    private func deleteAppRows(for appKey: String) throws {
        try deleteRows(in: "daily_usage", for: appKey)
        try deleteRows(in: "usage_buckets", for: appKey)

        let statement = try database.prepare("DELETE FROM apps WHERE app_key = ?;")
        defer { sqlite3_finalize(statement) }
        try database.bind(appKey, at: 1, in: statement)
        try database.stepDone(statement)
    }

    private func mergeApp(
        _ aggregate: AppAggregate,
        into apps: inout [String: AppAggregate]
    ) {
        if let existing = apps[aggregate.appKey] {
            apps[aggregate.appKey] = existing.merging(aggregate)
        } else {
            apps[aggregate.appKey] = aggregate
        }
    }

    private func prepareAppUpsert() throws -> OpaquePointer {
        try database.prepare(
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
    }

    private func prepareDailyUsageUpsert() throws -> OpaquePointer {
        try database.prepare(
            """
            INSERT INTO daily_usage (
                accounting_version, day, app_key, download_bytes,
                upload_bytes, sample_count, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accounting_version, day, app_key) DO UPDATE SET
                download_bytes = daily_usage.download_bytes + excluded.download_bytes,
                upload_bytes = daily_usage.upload_bytes + excluded.upload_bytes,
                sample_count = daily_usage.sample_count + excluded.sample_count,
                updated_at = excluded.updated_at;
            """
        )
    }

    private func prepareBucketUsageUpsert() throws -> OpaquePointer {
        try database.prepare(
            """
            INSERT INTO usage_buckets (
                accounting_version, bucket_start, app_key, download_bytes,
                upload_bytes, sample_count, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accounting_version, bucket_start, app_key) DO UPDATE SET
                download_bytes = usage_buckets.download_bytes + excluded.download_bytes,
                upload_bytes = usage_buckets.upload_bytes + excluded.upload_bytes,
                sample_count = usage_buckets.sample_count + excluded.sample_count,
                updated_at = excluded.updated_at;
            """
        )
    }

    private func upsertApp(
        _ aggregate: AppAggregate,
        using statement: OpaquePointer
    ) throws {
        try database.bind(aggregate.appKey, at: 1, in: statement)
        try database.bind(aggregate.bundleID, at: 2, in: statement)
        try database.bind(aggregate.bundlePath, at: 3, in: statement)
        try database.bind(aggregate.executablePath, at: 4, in: statement)
        try database.bind(aggregate.displayName, at: 5, in: statement)
        try database.bind(aggregate.category.rawValue, at: 6, in: statement)
        try database.bind(Self.timestamp(aggregate.firstSeenAt), at: 7, in: statement)
        try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 8, in: statement)
        try database.stepDone(statement)
        try database.reset(statement)
    }

    private func upsertDailyUsage(
        _ aggregate: DailyUsageAggregate,
        using statement: OpaquePointer
    ) throws {
        try database.bind(Self.accountingVersion, at: 1, in: statement)
        try database.bind(aggregate.day, at: 2, in: statement)
        try database.bind(aggregate.appKey, at: 3, in: statement)
        try database.bind(aggregate.downloadBytes, at: 4, in: statement)
        try database.bind(aggregate.uploadBytes, at: 5, in: statement)
        try database.bind(aggregate.sampleCount, at: 6, in: statement)
        try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 7, in: statement)
        try database.stepDone(statement)
        try database.reset(statement)
    }

    private func upsertBucketUsage(
        _ aggregate: UsageBucketAggregate,
        using statement: OpaquePointer
    ) throws {
        try database.bind(Self.accountingVersion, at: 1, in: statement)
        try database.bind(Self.epochSeconds(aggregate.bucketStart), at: 2, in: statement)
        try database.bind(aggregate.appKey, at: 3, in: statement)
        try database.bind(aggregate.downloadBytes, at: 4, in: statement)
        try database.bind(aggregate.uploadBytes, at: 5, in: statement)
        try database.bind(aggregate.sampleCount, at: 6, in: statement)
        try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 7, in: statement)
        try database.stepDone(statement)
        try database.reset(statement)
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

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func isSQLiteIntegerOverflow(_ error: Error) -> Bool {
        guard case let SQLiteDatabaseError.stepFailed(message) = error else { return false }
        return message.localizedCaseInsensitiveContains("integer overflow")
    }

    private static func epochSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private static func dateValue(_ value: String?) -> Date {
        guard let value, let seconds = Double(value) else { return .distantPast }
        return Date(timeIntervalSince1970: seconds)
    }
}
