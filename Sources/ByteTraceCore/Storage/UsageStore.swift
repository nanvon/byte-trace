import Foundation
import SQLite3

public final class UsageStore: @unchecked Sendable {
    public static let schemaVersion: Int64 = 15
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
    /// 单批清理的行数上限。够大以摊薄事务开销，够小以保证单批事务只持锁几十毫秒。
    private static let bucketPurgeBatchSize: Int64 = 5_000

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

    /// 打开失败是因为文件损坏或不是数据库，可以隔离后重建。
    public static func isCorruption(_ error: Error) -> Bool {
        if case .corrupt = error as? SQLiteDatabaseError { return true }
        return false
    }

    /// 打开失败是因为数据库由更新版本的 ByteTrace 创建；这种情况绝不能隔离重建。
    public static func isNewerSchema(_ error: Error) -> Bool {
        if case .unsupportedSchema = error as? SQLiteDatabaseError { return true }
        return false
    }

    /// 把数据库主文件与 -wal、-shm 一起改名保留在同一目录，返回改名后的主文件路径。
    /// 目标名 `usage.corrupt-<yyyyMMdd-HHmmss>.sqlite3`，重名时在时间后加 `-2`、`-3`。只移动，不复制、不删除。
    public static func quarantineDatabase(at url: URL, now: Date = Date()) throws -> URL {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: now)
        let sidecars = ["-wal", "-shm"]

        func candidate(_ index: Int) -> URL {
            let suffix = index == 1 ? "" : "-\(index)"
            let name = "\(stem).corrupt-\(timestamp)\(suffix)"
            return directory.appendingPathComponent(pathExtension.isEmpty ? name : "\(name).\(pathExtension)")
        }

        var index = 1
        var target = candidate(index)
        while ([target.path] + sidecars.map { target.path + $0 }).contains(where: fileManager.fileExists(atPath:)) {
            index += 1
            target = candidate(index)
        }

        let files = [(source: url, destination: target)] + sidecars.compactMap { suffix in
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { return nil }
            return (source, URL(fileURLWithPath: target.path + suffix))
        }
        var moved: [(source: URL, destination: URL)] = []
        do {
            for file in files {
                try fileManager.moveItem(at: file.source, to: file.destination)
                moved.append(file)
            }
        } catch {
            var unrestored: [String] = []
            for file in moved.reversed() {
                do {
                    try fileManager.moveItem(at: file.destination, to: file.source)
                } catch {
                    unrestored.append(file.destination.lastPathComponent)
                }
            }
            if !unrestored.isEmpty {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "隔离失败，以下文件未能移回原位：\(unrestored.joined(separator: "、"))。\(error.localizedDescription)"
                ])
            }
            throw error
        }
        return target
    }

    public static func defaultDatabaseURL(bundleIdentifier: String) -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("usage.sqlite3")
    }

    public func apply(
        _ aggregates: [DailyUsageAggregate],
        bucketAggregates: [UsageBucketAggregate] = [],
        routeAggregates: [RouteUsageAggregate] = [],
        domainAggregates: [DomainUsageAggregate] = []
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
            let routeStatement = try prepareRouteUsageUpsert()
            defer { sqlite3_finalize(routeStatement) }
            let programStatement = try prepareProgramUpsert()
            defer { sqlite3_finalize(programStatement) }

            var apps: [String: AppAggregate] = [:]
            var programs: [String: (program: AttributedProgram, firstSeenAt: Date, lastSeenAt: Date)] = [:]
            func noteProgram(_ program: AttributedProgram?, firstSeenAt: Date, lastSeenAt: Date) {
                guard let program else { return }
                if let existing = programs[program.key] {
                    programs[program.key] = (
                        lastSeenAt >= existing.lastSeenAt ? program : existing.program,
                        min(existing.firstSeenAt, firstSeenAt),
                        max(existing.lastSeenAt, lastSeenAt)
                    )
                } else {
                    programs[program.key] = (program, firstSeenAt, lastSeenAt)
                }
            }
            for aggregate in aggregates {
                mergeApp(AppAggregate(aggregate), into: &apps)
                noteProgram(aggregate.program, firstSeenAt: aggregate.firstSeenAt, lastSeenAt: aggregate.lastSeenAt)
            }
            for aggregate in bucketAggregates {
                mergeApp(AppAggregate(aggregate), into: &apps)
                noteProgram(aggregate.program, firstSeenAt: aggregate.firstSeenAt, lastSeenAt: aggregate.lastSeenAt)
            }

            for app in apps.values {
                try upsertApp(app, using: appStatement)
            }
            for entry in programs.values {
                try upsertProgram(
                    entry.program,
                    firstSeenAt: entry.firstSeenAt,
                    lastSeenAt: entry.lastSeenAt,
                    using: programStatement
                )
            }
            for aggregate in aggregates {
                try upsertDailyUsage(aggregate, using: dailyStatement)
            }
            for aggregate in bucketAggregates {
                try upsertBucketUsage(aggregate, using: bucketStatement)
            }
            for aggregate in routeAggregates {
                try upsertRouteUsage(aggregate, using: routeStatement)
            }
            if !domainAggregates.isEmpty {
                try applyDomainUsage(domainAggregates)
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
                   SUM(d.download_bytes), SUM(d.upload_bytes), SUM(d.sample_count)
            FROM daily_usage AS d
            JOIN apps AS a ON a.app_key = d.app_key
            WHERE d.accounting_version = ? AND d.day >= ? AND d.day <= ?
            GROUP BY d.day, d.app_key
            ORDER BY d.day ASC, (SUM(d.download_bytes) + SUM(d.upload_bytes)) DESC,
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

    /// 一段日期内每个应用按路径汇总的流量（只含当前口径）。
    /// 早于路径统计上线的日期没有行，调用方用日汇总减去这里的合计得到「未区分」部分。
    public func routeUsage(
        from startDay: String,
        through endDay: String
    ) throws -> [RouteUsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try database.prepare(
            """
            SELECT app_key, route, download_bytes, upload_bytes
            FROM daily_route_usage
            WHERE accounting_version = ? AND day >= ? AND day <= ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(Self.accountingVersion, at: 1, in: statement)
        try database.bind(startDay, at: 2, in: statement)
        try database.bind(endDay, at: 3, in: statement)

        struct Key: Hashable {
            let appKey: String
            let route: TrafficRoute
        }
        var order: [Key] = []
        var totals: [Key: (download: Int64, upload: Int64)] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }
            guard let appKey = database.columnString(statement, at: 0),
                  let route = TrafficRoute(rawValue: database.columnString(statement, at: 1) ?? "") else {
                continue
            }
            let key = Key(appKey: appKey, route: route)
            let existing = totals[key] ?? (0, 0)
            if totals[key] == nil { order.append(key) }
            totals[key] = (
                Self.saturatingAdd(existing.download, sqlite3_column_int64(statement, 2)),
                Self.saturatingAdd(existing.upload, sqlite3_column_int64(statement, 3))
            )
        }
        return order.compactMap { key in
            totals[key].map {
                RouteUsageRecord(
                    appKey: key.appKey,
                    route: key.route,
                    downloadBytes: $0.download,
                    uploadBytes: $0.upload
                )
            }
        }
    }

    /// 按宿主、域名和路径汇总当前口径的日记录。省略宿主时返回所有应用。
    public func domainUsage(
        appKey: String? = nil,
        from startDay: String,
        through endDay: String
    ) throws -> [DomainUsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        let appFilter = appKey == nil ? "" : "AND d.app_key = ?"
        let statement = try database.prepare(
            """
            SELECT d.app_key, d.domain, d.route, d.download_bytes, d.upload_bytes
            FROM daily_domain_usage AS d
            JOIN apps AS a ON a.app_key = d.app_key
            WHERE d.accounting_version = ? AND d.day >= ? AND d.day <= ?
                AND a.category != ? \(appFilter);
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(Self.accountingVersion, at: 1, in: statement)
        try database.bind(startDay, at: 2, in: statement)
        try database.bind(endDay, at: 3, in: statement)
        try database.bind(AppCategory.proxyTransport.rawValue, at: 4, in: statement)
        if let appKey { try database.bind(appKey, at: 5, in: statement) }

        struct Key: Hashable {
            let appKey: String
            let domain: String
            let route: TrafficRoute
        }
        var totals: [Key: (download: Int64, upload: Int64)] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }
            guard let app = database.columnString(statement, at: 0),
                  let domain = database.columnString(statement, at: 1),
                  let route = TrafficRoute(rawValue: database.columnString(statement, at: 2) ?? "") else { continue }
            let key = Key(appKey: app, domain: domain, route: route)
            let existing = totals[key] ?? (0, 0)
            totals[key] = (
                Self.saturatingAdd(existing.download, sqlite3_column_int64(statement, 3)),
                Self.saturatingAdd(existing.upload, sqlite3_column_int64(statement, 4))
            )
        }
        return totals.map { key, bytes in
            DomainUsageRecord(appKey: key.appKey, domain: key.domain, route: key.route,
                              downloadBytes: bytes.download, uploadBytes: bytes.upload)
        }
    }

    public func bucketUsage(from start: Date, to end: Date) throws -> [UsageBucketRecord] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try database.prepare(
            """
            SELECT b.bucket_start, b.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   SUM(b.download_bytes), SUM(b.upload_bytes), SUM(b.sample_count)
            FROM usage_buckets AS b
            JOIN apps AS a ON a.app_key = b.app_key
            WHERE b.accounting_version = ? AND b.bucket_start >= ? AND b.bucket_start < ?
            GROUP BY b.bucket_start, b.app_key
            ORDER BY b.bucket_start ASC, (SUM(b.download_bytes) + SUM(b.upload_bytes)) DESC,
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

    /// - Parameters:
    ///   - appKey: 只看这个宿主。
    ///   - programIdentity: 只看这个程序（跨宿主）；应用自身用宿主 appKey 表示，见 `ProgramUsageRecord.programIdentity`。
    public func bucketTimeline(
        from start: Date,
        to end: Date,
        appKey: String? = nil,
        programIdentity: String? = nil,
        excludingProxyTransport: Bool = true
    ) throws -> [UsageTimelineRecord] {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try queryBucketTimeline(
                from: start,
                to: end,
                appKey: appKey,
                programIdentity: programIdentity,
                excludingProxyTransport: excludingProxyTransport
            )
        } catch where Self.isSQLiteIntegerOverflow(error) {
            guard programIdentity == nil else { throw error }
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
        programIdentity: String?,
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
        if programIdentity != nil {
            conditions.append("(CASE WHEN b.program_key = '' THEN b.app_key ELSE b.program_key END) = ?")
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
        if let programIdentity {
            try database.bind(programIdentity, at: bindingIndex, in: statement)
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

    /// Per-app traffic merged into fixed slots of `slotSeconds`, aligned to the
    /// Unix epoch. Rows are ordered by slot, then by total bytes descending.
    /// Reading minute rows directly would return tens of thousands of rows for a
    /// full day; grouping in SQL keeps a 10-minute daily chart in the low thousands.
    public func bucketTimelineByApp(
        from start: Date,
        to end: Date,
        slotSeconds: Int64,
        excludingProxyTransport: Bool = true
    ) throws -> [UsageAppTimelineRecord] {
        precondition(slotSeconds > 0, "slotSeconds must be positive")
        lock.lock()
        defer { lock.unlock() }
        do {
            return try queryBucketTimelineByApp(
                from: start,
                to: end,
                slotSeconds: slotSeconds,
                excludingProxyTransport: excludingProxyTransport
            )
        } catch where Self.isSQLiteIntegerOverflow(error) {
            return try saturatedBucketTimelineByApp(
                from: start,
                to: end,
                slotSeconds: slotSeconds,
                excludingProxyTransport: excludingProxyTransport
            )
        }
    }

    private func queryBucketTimelineByApp(
        from start: Date,
        to end: Date,
        slotSeconds: Int64,
        excludingProxyTransport: Bool
    ) throws -> [UsageAppTimelineRecord] {
        var conditions = [
            "b.accounting_version = ?",
            "b.bucket_start >= ?",
            "b.bucket_start < ?"
        ]
        if excludingProxyTransport {
            conditions.append("a.category != ?")
        }

        let statement = try database.prepare(
            """
            SELECT (b.bucket_start / ?) * ? AS slot_start, b.app_key,
                   SUM(b.download_bytes), SUM(b.upload_bytes)
            FROM usage_buckets AS b
            JOIN apps AS a ON a.app_key = b.app_key
            WHERE \(conditions.joined(separator: " AND "))
            GROUP BY slot_start, b.app_key
            ORDER BY slot_start ASC,
                     (SUM(b.download_bytes) + SUM(b.upload_bytes)) DESC,
                     b.app_key ASC;
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(slotSeconds, at: 1, in: statement)
        try database.bind(slotSeconds, at: 2, in: statement)
        try database.bind(Self.accountingVersion, at: 3, in: statement)
        try database.bind(Self.epochSeconds(start), at: 4, in: statement)
        try database.bind(Self.epochSeconds(end), at: 5, in: statement)
        if excludingProxyTransport {
            try database.bind(AppCategory.proxyTransport.rawValue, at: 6, in: statement)
        }

        var records: [UsageAppTimelineRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }
            records.append(
                UsageAppTimelineRecord(
                    slotStart: Date(
                        timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))
                    ),
                    appKey: database.columnString(statement, at: 1) ?? "",
                    downloadBytes: sqlite3_column_int64(statement, 2),
                    uploadBytes: sqlite3_column_int64(statement, 3)
                )
            )
        }
        return records
    }

    private func saturatedBucketTimelineByApp(
        from start: Date,
        to end: Date,
        slotSeconds: Int64,
        excludingProxyTransport: Bool
    ) throws -> [UsageAppTimelineRecord] {
        struct SlotKey: Hashable {
            let slotStart: Int64
            let appKey: String
        }
        var totals: [SlotKey: (download: Int64, upload: Int64)] = [:]
        for record in try bucketUsage(from: start, to: end) {
            if excludingProxyTransport, record.category == .proxyTransport { continue }
            let seconds = Self.epochSeconds(record.bucketStart)
            let key = SlotKey(
                slotStart: (seconds / slotSeconds) * slotSeconds,
                appKey: record.appKey
            )
            let existing = totals[key] ?? (0, 0)
            totals[key] = (
                Self.saturatingAdd(existing.download, record.downloadBytes),
                Self.saturatingAdd(existing.upload, record.uploadBytes)
            )
        }
        return totals
            .map { key, value in
                UsageAppTimelineRecord(
                    slotStart: Date(timeIntervalSince1970: TimeInterval(key.slotStart)),
                    appKey: key.appKey,
                    downloadBytes: value.download,
                    uploadBytes: value.upload
                )
            }
            .sorted {
                if $0.slotStart != $1.slotStart { return $0.slotStart < $1.slotStart }
                let left = Self.saturatingAdd($0.downloadBytes, $0.uploadBytes)
                let right = Self.saturatingAdd($1.downloadBytes, $1.uploadBytes)
                if left != right { return left > right }
                return $0.appKey < $1.appKey
            }
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

    /// 分批清理过期分钟桶。
    ///
    /// cutoff 由调用方在任务开始时固定，每批一个独立的短事务：保留策略在后台队列执行，
    /// 但与主线程落库共用同一把 `lock`。首次启用 7/30/90 天策略可能要删几百万行，
    /// 单事务删完会让主线程的 flush 一直阻塞在锁上；切成短事务后落库最多等一批。
    /// 每批提交即生效，中断后下次清理从剩余数据继续，`daily_usage` 与 `apps` 不受影响。
    public func purgeBuckets(before date: Date) throws -> Int64 {
        var totalDeleted: Int64 = 0
        while true {
            let deleted = try purgeBucketBatch(before: date)
            totalDeleted = Self.saturatingAdd(totalDeleted, deleted)
            guard deleted >= Self.bucketPurgeBatchSize else { return totalDeleted }
            // NSRecursiveLock 不保证公平：批次之间立刻重新加锁，可能让主线程的 flush
            // 长时间抢不到。让出几毫秒换取落库不被连续批次拖住。
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    private func purgeBucketBatch(before date: Date) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let usageDeleted = try deleteBuckets(
                from: "usage_buckets",
                before: date,
                limit: Self.bucketPurgeBatchSize
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

    /// 一段日期内每个宿主下每个程序每天的流量（不含代理传输）。
    public func programUsage(
        from startDay: String,
        through endDay: String
    ) throws -> [ProgramUsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try queryProgramUsage(
            """
            SELECT d.day, d.app_key, d.program_key, p.display_name, p.category, p.executable_path,
                   d.download_bytes, d.upload_bytes
            FROM daily_usage AS d
            JOIN apps AS a ON a.app_key = d.app_key
            LEFT JOIN programs AS p ON p.program_key = d.program_key
            WHERE d.accounting_version = ? AND d.day >= ? AND d.day <= ? AND a.category != ?;
            """,
            bind: { statement in
                try self.database.bind(Self.accountingVersion, at: 1, in: statement)
                try self.database.bind(startDay, at: 2, in: statement)
                try self.database.bind(endDay, at: 3, in: statement)
                try self.database.bind(AppCategory.proxyTransport.rawValue, at: 4, in: statement)
            },
            day: { self.database.columnString($0, at: 0) ?? startDay }
        )
    }

    /// 一段时间内每个宿主下每个程序的流量（分钟桶，整段合成一行，不含代理传输）。
    public func bucketProgramUsage(from start: Date, to end: Date) throws -> [ProgramUsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try queryProgramUsage(
            """
            SELECT MIN(b.bucket_start), b.app_key, b.program_key, p.display_name, p.category, p.executable_path,
                   SUM(b.download_bytes), SUM(b.upload_bytes)
            FROM usage_buckets AS b
            JOIN apps AS a ON a.app_key = b.app_key
            LEFT JOIN programs AS p ON p.program_key = b.program_key
            WHERE b.accounting_version = ? AND b.bucket_start >= ? AND b.bucket_start < ? AND a.category != ?
            GROUP BY b.app_key, b.program_key;
            """,
            bind: { statement in
                try self.database.bind(Self.accountingVersion, at: 1, in: statement)
                try self.database.bind(Self.epochSeconds(start), at: 2, in: statement)
                try self.database.bind(Self.epochSeconds(end), at: 3, in: statement)
                try self.database.bind(AppCategory.proxyTransport.rawValue, at: 4, in: statement)
            },
            day: { Self.dayString(for: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64($0, 0)))) }
        )
    }

    private func queryProgramUsage(
        _ sql: String,
        bind: (OpaquePointer) throws -> Void,
        day: (OpaquePointer) -> String
    ) throws -> [ProgramUsageRecord] {
        let statement = try database.prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement)
        var records: [ProgramUsageRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }
            records.append(
                ProgramUsageRecord(
                    day: day(statement),
                    appKey: database.columnString(statement, at: 1) ?? "",
                    programKey: database.columnString(statement, at: 2) ?? "",
                    programName: database.columnString(statement, at: 3),
                    programCategory: database.columnString(statement, at: 4).flatMap(AppCategory.init(rawValue:)),
                    programExecutablePath: database.columnString(statement, at: 5),
                    downloadBytes: sqlite3_column_int64(statement, 6),
                    uploadBytes: sqlite3_column_int64(statement, 7)
                )
            )
        }
        return records
    }

    /// 一段日期内每个宿主下每个程序按路径汇总的流量。
    public func programRouteUsage(
        from startDay: String,
        through endDay: String
    ) throws -> [ProgramRouteUsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try database.prepare(
            """
            SELECT app_key, program_key, route, download_bytes, upload_bytes
            FROM daily_route_usage
            WHERE accounting_version = ? AND day >= ? AND day <= ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try database.bind(Self.accountingVersion, at: 1, in: statement)
        try database.bind(startDay, at: 2, in: statement)
        try database.bind(endDay, at: 3, in: statement)

        struct Key: Hashable {
            let appKey: String
            let programKey: String
            let route: TrafficRoute
        }
        var order: [Key] = []
        var totals: [Key: Int64] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }
            guard let appKey = database.columnString(statement, at: 0),
                  let route = TrafficRoute(rawValue: database.columnString(statement, at: 2) ?? "") else {
                continue
            }
            let key = Key(appKey: appKey, programKey: database.columnString(statement, at: 1) ?? "", route: route)
            if totals[key] == nil { order.append(key) }
            let bytes = Self.saturatingAdd(sqlite3_column_int64(statement, 3), sqlite3_column_int64(statement, 4))
            totals[key] = Self.saturatingAdd(totals[key] ?? 0, bytes)
        }
        return order.compactMap { key in
            totals[key].map {
                ProgramRouteUsageRecord(appKey: key.appKey, programKey: key.programKey, route: key.route, totalBytes: $0)
            }
        }
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
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try database.execute(
                """
                DELETE FROM usage_buckets;
                DELETE FROM daily_route_usage;
                DELETE FROM daily_domain_usage;
                DELETE FROM process_names;
                DELETE FROM daily_usage;
                DELETE FROM programs;
                DELETE FROM apps;
                DELETE FROM collector_events;
                """
            )
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    /// nettop 进程名最近一次解析到的宿主与程序，覆盖写入；只用于重启后预填名称缓存。
    public func recordProcessNames(_ names: [String: ProcessNameAttribution], at date: Date = Date()) throws {
        guard !names.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let statement = try database.prepare(
            """
            INSERT INTO process_names (process_name, app_key, program_key, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(process_name) DO UPDATE SET
                app_key = excluded.app_key,
                program_key = excluded.program_key,
                updated_at = excluded.updated_at;
            """
        )
        defer { sqlite3_finalize(statement) }
        for (processName, attribution) in names {
            try database.bind(processName, at: 1, in: statement)
            try database.bind(attribution.appKey, at: 2, in: statement)
            try database.bind(attribution.programKey, at: 3, in: statement)
            try database.bind(Self.timestamp(date), at: 4, in: statement)
            try database.stepDone(statement)
            try database.reset(statement)
        }
    }

    /// 启动时预填名称缓存用：已记录的进程名归属，加上按可执行文件名（nettop 最多 15 个字符）
    /// 推出的归属——应用按自己的可执行文件，程序按最近一次出现时所在的宿主。已记录的优先，同名取最近出现的。
    public func rememberedProcessAttributions() throws -> [RememberedProcessAttribution] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try database.prepare(
            """
            SELECT n.process_name, a.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   pr.program_key, pr.display_name, pr.category, pr.executable_path,
                   NULL, 2, CAST(a.last_seen_at AS REAL)
            FROM process_names AS n
            JOIN apps AS a ON a.app_key = n.app_key
            LEFT JOIN programs AS pr ON pr.program_key = n.program_key AND n.program_key != ''
            UNION ALL
            SELECT NULL, a.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   NULL, NULL, NULL, NULL,
                   a.executable_path, 1, CAST(a.last_seen_at AS REAL)
            FROM apps AS a
            WHERE a.executable_path IS NOT NULL AND a.app_key NOT LIKE 'proxy:%'
            UNION ALL
            SELECT NULL, a.app_key, a.display_name, a.category,
                   a.bundle_id, a.bundle_path, a.executable_path,
                   pr.program_key, pr.display_name, pr.category, pr.executable_path,
                   pr.executable_path, 1, CAST(pr.last_seen_at AS REAL)
            FROM programs AS pr
            JOIN (
                SELECT program_key, app_key, MAX(updated_at) FROM daily_usage
                WHERE program_key != '' GROUP BY program_key
            ) AS latest ON latest.program_key = pr.program_key
            JOIN apps AS a ON a.app_key = latest.app_key
            WHERE pr.executable_path IS NOT NULL AND a.app_key NOT LIKE 'proxy:%'
            ORDER BY 13 DESC, 14 DESC;
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [RememberedProcessAttribution] = []
        var seen: Set<String> = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }
            guard let appKey = database.columnString(statement, at: 1),
                  let processName = database.columnString(statement, at: 0)
                    ?? database.columnString(statement, at: 11).map({
                        String(URL(fileURLWithPath: $0).lastPathComponent.prefix(15))
                    }),
                  !processName.isEmpty,
                  seen.insert(processName).inserted else { continue }
            var program: AttributedProgram?
            if let programKey = database.columnString(statement, at: 7), !programKey.isEmpty {
                program = AttributedProgram(
                    key: programKey,
                    displayName: database.columnString(statement, at: 8) ?? programKey,
                    category: AppCategory(rawValue: database.columnString(statement, at: 9) ?? "") ?? .unclassified,
                    executablePath: database.columnString(statement, at: 10)
                )
            }
            result.append(
                RememberedProcessAttribution(
                    processName: processName,
                    appKey: appKey,
                    displayName: database.columnString(statement, at: 2) ?? processName,
                    category: AppCategory(rawValue: database.columnString(statement, at: 3) ?? "")
                        ?? .unclassified,
                    bundleID: database.columnString(statement, at: 4),
                    bundlePath: database.columnString(statement, at: 5),
                    executablePath: database.columnString(statement, at: 6),
                    program: program
                )
            )
        }
        return result
    }

    private func migrate() throws {
        let currentVersion = try database.scalarInt64("PRAGMA user_version;")
        guard currentVersion <= Self.schemaVersion else {
            throw SQLiteDatabaseError.unsupportedSchema(currentVersion)
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

        if currentVersion <= 6 {
            try migrateVersionedExecutablePaths()
        }

        if currentVersion <= 7 {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS daily_route_usage (
                    accounting_version INTEGER NOT NULL CHECK (accounting_version > 0),
                    day TEXT NOT NULL,
                    app_key TEXT NOT NULL,
                    route TEXT NOT NULL,
                    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (accounting_version, day, app_key, route),
                    FOREIGN KEY (app_key) REFERENCES apps(app_key)
                );

                PRAGMA user_version = 8;
                """
            )
        }

        if currentVersion <= 8 {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS app_launchers (
                    app_key TEXT PRIMARY KEY,
                    launcher_name TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                PRAGMA user_version = 9;
                """
            )
        }

        if currentVersion <= 10 {
            // 先建表：后面的合并会把进程名映射一起改到新 appKey。
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS process_names (
                    process_name TEXT PRIMARY KEY,
                    app_key TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                """
            )
        }

        if currentVersion <= 11 {
            try migrateHostsAndPrograms()
        }

        if currentVersion <= 12 {
            try mergeLegacyHost()
        }

        if currentVersion <= 13 {
            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS daily_domain_usage (
                    accounting_version INTEGER NOT NULL CHECK (accounting_version > 0),
                    day TEXT NOT NULL,
                    app_key TEXT NOT NULL,
                    domain TEXT NOT NULL,
                    route TEXT NOT NULL,
                    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (accounting_version, day, app_key, domain, route),
                    FOREIGN KEY (app_key) REFERENCES apps(app_key)
                );
                PRAGMA user_version = 14;
                """
            )
        }

        if currentVersion <= 14 {
            // (accounting_version, bucket_start) 是主键的前缀，分钟桶查询改走主键索引，查询计划不变。
            try database.execute(
                """
                DROP INDEX IF EXISTS idx_usage_buckets_start;
                PRAGMA user_version = 15;
                """
            )
        }
    }

    struct MigrationApp {
        let appKey: String
        let bundlePath: String?
        let executablePath: String?
        let displayName: String
        let category: String
        let firstSeenAt: String
        let lastSeenAt: String

        var isApplication: Bool {
            appKey.hasPrefix("bundle:") || appKey.hasPrefix("app:")
        }

        var bundleID: String? {
            appKey.hasPrefix("bundle:") ? String(appKey.dropFirst("bundle:".count)) : nil
        }
    }

    /// 旧记录在新结构里的位置：宿主 appKey 与程序（nil 为宿主应用自身）。
    struct HostProgramTarget: Equatable {
        let hostKey: String
        let program: AttributedProgram?
    }

    /// 版本 12：日汇总、分钟桶、路径表加入 `program_key`，旧记录按「宿主 + 程序」重新落位：
    /// - 应用记录：宿主就是它，程序为应用自身；嵌套在另一个 `.app` 里的归外层应用；附属应用归主应用、程序为它自己；
    ///   `~/Library/Application Support` 下的附属包与框架里的 `.app`（Python.app）不是宿主，按程序处理。
    /// - 命令行记录（`command:` / `exec:` / `process:` / `unknown:`）：程序按新规则重算（`bin` 下的工具按名称合并）；
    ///   系统目录下的归「macOS 系统」，位于某个应用数据目录里的归该应用自身，编辑器扩展的二进制归编辑器；
    ///   其余以前没有记下宿主，归「命令行工具」，不按最近一次启动者猜。
    /// 一次事务内重建三张表并删除 `app_launchers`；字节总量不变。
    private func migrateHostsAndPrograms() throws {
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let apps = try loadMigrationApps()
            let plan = Self.hostProgramPlan(for: apps)

            try database.execute(
                """
                CREATE TABLE IF NOT EXISTS programs (
                    program_key TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    category TEXT NOT NULL,
                    executable_path TEXT,
                    first_seen_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL
                );
                DROP TABLE IF EXISTS temp.v12_key_map;
                CREATE TEMP TABLE v12_key_map (
                    old_key TEXT PRIMARY KEY,
                    host_key TEXT NOT NULL,
                    program_key TEXT NOT NULL
                );
                """
            )

            let appsByKey = Dictionary(apps.map { ($0.appKey, $0) }, uniquingKeysWith: { first, _ in first })
            let mapStatement = try database.prepare(
                "INSERT INTO v12_key_map (old_key, host_key, program_key) VALUES (?, ?, ?);"
            )
            defer { sqlite3_finalize(mapStatement) }
            let programStatement = try prepareProgramUpsert()
            defer { sqlite3_finalize(programStatement) }
            let appStatement = try database.prepare(
                """
                INSERT INTO apps (
                    app_key, bundle_id, bundle_path, executable_path,
                    display_name, category, first_seen_at, last_seen_at
                ) VALUES (?, NULL, NULL, NULL, ?, ?, ?, ?)
                ON CONFLICT(app_key) DO UPDATE SET
                    first_seen_at = MIN(apps.first_seen_at, excluded.first_seen_at),
                    last_seen_at = MAX(apps.last_seen_at, excluded.last_seen_at);
                """
            )
            defer { sqlite3_finalize(appStatement) }

            for (oldKey, target) in plan.sorted(by: { $0.key < $1.key }) {
                guard let app = appsByKey[oldKey] else { continue }
                try database.bind(oldKey, at: 1, in: mapStatement)
                try database.bind(target.hostKey, at: 2, in: mapStatement)
                try database.bind(target.program?.key ?? "", at: 3, in: mapStatement)
                try database.stepDone(mapStatement)
                try database.reset(mapStatement)

                if let program = target.program {
                    try upsertProgram(
                        program,
                        firstSeenAt: Self.dateValue(app.firstSeenAt),
                        lastSeenAt: Self.dateValue(app.lastSeenAt),
                        using: programStatement
                    )
                }
                // 虚拟宿主建一行；已有应用只放宽首次出现时间。
                let hostName = VirtualHost.displayName(for: target.hostKey)
                    ?? appsByKey[target.hostKey]?.displayName
                    ?? target.hostKey
                let hostCategory = VirtualHost.isVirtual(target.hostKey)
                    ? VirtualHost.category(for: target.hostKey).rawValue
                    : appsByKey[target.hostKey]?.category ?? AppCategory.userApp.rawValue
                try database.bind(target.hostKey, at: 1, in: appStatement)
                try database.bind(hostName, at: 2, in: appStatement)
                try database.bind(hostCategory, at: 3, in: appStatement)
                try database.bind(app.firstSeenAt, at: 4, in: appStatement)
                try database.bind(VirtualHost.isVirtual(target.hostKey) ? app.lastSeenAt : "0.000000", at: 5, in: appStatement)
                try database.stepDone(appStatement)
                try database.reset(appStatement)
            }

            try database.execute(
                """
                CREATE TABLE daily_usage_v12 (
                    accounting_version INTEGER NOT NULL CHECK (accounting_version > 0),
                    day TEXT NOT NULL,
                    app_key TEXT NOT NULL,
                    program_key TEXT NOT NULL DEFAULT '',
                    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                    sample_count INTEGER NOT NULL DEFAULT 0 CHECK (sample_count >= 0),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (accounting_version, day, app_key, program_key),
                    FOREIGN KEY (app_key) REFERENCES apps(app_key)
                );
                INSERT INTO daily_usage_v12 (
                    accounting_version, day, app_key, program_key,
                    download_bytes, upload_bytes, sample_count, updated_at
                )
                SELECT d.accounting_version, d.day, COALESCE(m.host_key, d.app_key), COALESCE(m.program_key, ''),
                       SUM(d.download_bytes), SUM(d.upload_bytes), SUM(d.sample_count), MAX(d.updated_at)
                FROM daily_usage AS d
                LEFT JOIN v12_key_map AS m ON m.old_key = d.app_key
                GROUP BY 1, 2, 3, 4;

                CREATE TABLE usage_buckets_v12 (
                    accounting_version INTEGER NOT NULL CHECK (accounting_version > 0),
                    bucket_start INTEGER NOT NULL,
                    app_key TEXT NOT NULL,
                    program_key TEXT NOT NULL DEFAULT '',
                    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                    sample_count INTEGER NOT NULL DEFAULT 0 CHECK (sample_count >= 0),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (accounting_version, bucket_start, app_key, program_key),
                    FOREIGN KEY (app_key) REFERENCES apps(app_key)
                );
                INSERT INTO usage_buckets_v12 (
                    accounting_version, bucket_start, app_key, program_key,
                    download_bytes, upload_bytes, sample_count, updated_at
                )
                SELECT b.accounting_version, b.bucket_start, COALESCE(m.host_key, b.app_key), COALESCE(m.program_key, ''),
                       SUM(b.download_bytes), SUM(b.upload_bytes), SUM(b.sample_count), MAX(b.updated_at)
                FROM usage_buckets AS b
                LEFT JOIN v12_key_map AS m ON m.old_key = b.app_key
                GROUP BY 1, 2, 3, 4;

                CREATE TABLE daily_route_usage_v12 (
                    accounting_version INTEGER NOT NULL CHECK (accounting_version > 0),
                    day TEXT NOT NULL,
                    app_key TEXT NOT NULL,
                    program_key TEXT NOT NULL DEFAULT '',
                    route TEXT NOT NULL,
                    download_bytes INTEGER NOT NULL DEFAULT 0 CHECK (download_bytes >= 0),
                    upload_bytes INTEGER NOT NULL DEFAULT 0 CHECK (upload_bytes >= 0),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (accounting_version, day, app_key, program_key, route),
                    FOREIGN KEY (app_key) REFERENCES apps(app_key)
                );
                INSERT INTO daily_route_usage_v12 (
                    accounting_version, day, app_key, program_key, route,
                    download_bytes, upload_bytes, updated_at
                )
                SELECT r.accounting_version, r.day, COALESCE(m.host_key, r.app_key), COALESCE(m.program_key, ''),
                       r.route, SUM(r.download_bytes), SUM(r.upload_bytes), MAX(r.updated_at)
                FROM daily_route_usage AS r
                LEFT JOIN v12_key_map AS m ON m.old_key = r.app_key
                GROUP BY 1, 2, 3, 4, 5;

                DROP INDEX IF EXISTS idx_usage_buckets_start;
                DROP TABLE daily_usage;
                DROP TABLE usage_buckets;
                DROP TABLE daily_route_usage;
                ALTER TABLE daily_usage_v12 RENAME TO daily_usage;
                ALTER TABLE usage_buckets_v12 RENAME TO usage_buckets;
                ALTER TABLE daily_route_usage_v12 RENAME TO daily_route_usage;
                CREATE INDEX idx_usage_buckets_start
                    ON usage_buckets(accounting_version, bucket_start);

                ALTER TABLE process_names ADD COLUMN program_key TEXT NOT NULL DEFAULT '';
                UPDATE process_names SET
                    program_key = COALESCE(
                        (SELECT program_key FROM v12_key_map WHERE old_key = process_names.app_key), ''
                    ),
                    app_key = COALESCE(
                        (SELECT host_key FROM v12_key_map WHERE old_key = process_names.app_key), app_key
                    );

                DELETE FROM apps
                WHERE app_key IN (SELECT old_key FROM v12_key_map WHERE host_key != old_key);
                DROP TABLE v12_key_map;
                DROP TABLE IF EXISTS app_launchers;
                PRAGMA user_version = 12;
                """
            )
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    /// 版本 13：开发期的版本 12 曾把没有记下宿主的命令行记录放在单独的 `host:legacy`，
    /// 现在并入「命令行工具」（`host:other`）；其中可执行文件在系统目录的（系统框架里的 `.app`）归「macOS 系统」。
    /// 同一位置已有的行累加合并，字节总量不变。
    private func mergeLegacyHost() throws {
        let legacyKey = "host:legacy"
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var systemPrograms: [String] = []
            let statement = try database.prepare(
                """
                SELECT DISTINCT d.program_key, p.executable_path
                FROM daily_usage AS d
                LEFT JOIN programs AS p ON p.program_key = d.program_key
                WHERE d.app_key = 'host:legacy';
                """
            )
            defer { sqlite3_finalize(statement) }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw SQLiteDatabaseError.stepFailed(database.errorMessage)
                }
                guard let programKey = database.columnString(statement, at: 0) else { continue }
                let path = database.columnString(statement, at: 1)
                    ?? (programKey.hasPrefix("exec:") ? String(programKey.dropFirst("exec:".count)) : nil)
                if ProcessAttributor.isSystemExecutable(path) {
                    systemPrograms.append(programKey)
                }
            }

            try database.execute(
                """
                DROP TABLE IF EXISTS temp.v13_system_programs;
                CREATE TEMP TABLE v13_system_programs (program_key TEXT PRIMARY KEY);
                """
            )
            let insertSystem = try database.prepare("INSERT OR IGNORE INTO v13_system_programs VALUES (?);")
            defer { sqlite3_finalize(insertSystem) }
            for programKey in systemPrograms {
                try database.bind(programKey, at: 1, in: insertSystem)
                try database.stepDone(insertSystem)
                try database.reset(insertSystem)
            }

            let target = """
                CASE WHEN program_key IN (SELECT program_key FROM v13_system_programs)
                     THEN '\(VirtualHost.systemKey)' ELSE '\(VirtualHost.otherKey)' END
                """
            try database.execute(
                """
                INSERT INTO apps (
                    app_key, bundle_id, bundle_path, executable_path,
                    display_name, category, first_seen_at, last_seen_at
                )
                SELECT '\(VirtualHost.systemKey)', NULL, NULL, NULL, 'macOS 系统', 'system_process', first_seen_at, last_seen_at
                FROM apps WHERE app_key = '\(legacyKey)'
                UNION ALL
                SELECT '\(VirtualHost.otherKey)', NULL, NULL, NULL, 'x', 'unclassified', first_seen_at, last_seen_at
                FROM apps WHERE app_key = '\(legacyKey)'
                ON CONFLICT(app_key) DO UPDATE SET
                    first_seen_at = MIN(apps.first_seen_at, excluded.first_seen_at),
                    last_seen_at = MAX(apps.last_seen_at, excluded.last_seen_at);
                UPDATE apps SET display_name = '\(VirtualHost.displayName(for: VirtualHost.otherKey) ?? "")'
                WHERE app_key = '\(VirtualHost.otherKey)';

                INSERT INTO daily_usage (
                    accounting_version, day, app_key, program_key,
                    download_bytes, upload_bytes, sample_count, updated_at
                )
                SELECT accounting_version, day, \(target), program_key,
                       download_bytes, upload_bytes, sample_count, updated_at
                FROM daily_usage WHERE app_key = '\(legacyKey)'
                ON CONFLICT(accounting_version, day, app_key, program_key) DO UPDATE SET
                    download_bytes = daily_usage.download_bytes + excluded.download_bytes,
                    upload_bytes = daily_usage.upload_bytes + excluded.upload_bytes,
                    sample_count = daily_usage.sample_count + excluded.sample_count,
                    updated_at = MAX(daily_usage.updated_at, excluded.updated_at);
                DELETE FROM daily_usage WHERE app_key = '\(legacyKey)';

                INSERT INTO usage_buckets (
                    accounting_version, bucket_start, app_key, program_key,
                    download_bytes, upload_bytes, sample_count, updated_at
                )
                SELECT accounting_version, bucket_start, \(target), program_key,
                       download_bytes, upload_bytes, sample_count, updated_at
                FROM usage_buckets WHERE app_key = '\(legacyKey)'
                ON CONFLICT(accounting_version, bucket_start, app_key, program_key) DO UPDATE SET
                    download_bytes = usage_buckets.download_bytes + excluded.download_bytes,
                    upload_bytes = usage_buckets.upload_bytes + excluded.upload_bytes,
                    sample_count = usage_buckets.sample_count + excluded.sample_count,
                    updated_at = MAX(usage_buckets.updated_at, excluded.updated_at);
                DELETE FROM usage_buckets WHERE app_key = '\(legacyKey)';

                INSERT INTO daily_route_usage (
                    accounting_version, day, app_key, program_key, route,
                    download_bytes, upload_bytes, updated_at
                )
                SELECT accounting_version, day, \(target), program_key, route,
                       download_bytes, upload_bytes, updated_at
                FROM daily_route_usage WHERE app_key = '\(legacyKey)'
                ON CONFLICT(accounting_version, day, app_key, program_key, route) DO UPDATE SET
                    download_bytes = daily_route_usage.download_bytes + excluded.download_bytes,
                    upload_bytes = daily_route_usage.upload_bytes + excluded.upload_bytes,
                    updated_at = MAX(daily_route_usage.updated_at, excluded.updated_at);
                DELETE FROM daily_route_usage WHERE app_key = '\(legacyKey)';

                UPDATE process_names SET app_key = \(target) WHERE app_key = '\(legacyKey)';
                DELETE FROM apps WHERE app_key = '\(legacyKey)';
                DELETE FROM apps
                WHERE app_key = '\(VirtualHost.systemKey)'
                  AND NOT EXISTS (SELECT 1 FROM daily_usage WHERE app_key = '\(VirtualHost.systemKey)');
                DELETE FROM apps
                WHERE app_key = '\(VirtualHost.otherKey)'
                  AND NOT EXISTS (SELECT 1 FROM daily_usage WHERE app_key = '\(VirtualHost.otherKey)');
                DROP TABLE v13_system_programs;
                PRAGMA user_version = 13;
                """
            )
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    /// 编辑器扩展目录 → 编辑器 bundle ID。
    private static let editorExtensionDirectories: [String: String] = [
        "/.vscode/extensions/": "com.microsoft.VSCode",
        "/.vscode-insiders/extensions/": "com.microsoft.VSCodeInsiders",
        "/.cursor/extensions/": "com.todesktop.230313mzl4w4u92",
        "/.windsurf/extensions/": "com.exafunction.windsurf"
    ]

    /// 每条需要改位置的旧记录 → 新的宿主与程序；不在结果里的（普通应用、代理）原样保留。
    static func hostProgramPlan(for apps: [MigrationApp]) -> [String: HostProgramTarget] {
        let appsByKey = Dictionary(apps.map { ($0.appKey, $0) }, uniquingKeysWith: { first, _ in first })
        func isHostPath(_ path: String) -> Bool {
            !path.contains("/Library/Application Support/") && !path.contains(".framework/")
        }
        let hosts = apps.filter { app in
            guard app.isApplication else { return false }
            guard let bundlePath = app.bundlePath else { return true }
            return isHostPath(bundlePath) && !bundlePath.contains(".app/")
        }
        var hostByPath: [String: MigrationApp] = [:]
        for host in hosts {
            if let bundlePath = host.bundlePath { hostByPath[bundlePath] = host }
        }
        /// 目录名对应的唯一宿主：bundle ID 相同，或展示名相同（不区分大小写）。
        func owner(ofDirectory directory: String) -> MigrationApp? {
            let byBundleID = hosts.filter { $0.bundleID == directory }
            if byBundleID.count == 1 { return byBundleID[0] }
            let byName = hosts.filter { $0.displayName.caseInsensitiveCompare(directory) == .orderedSame }
            return byName.count == 1 ? byName[0] : nil
        }
        func directory(after marker: String, in path: String) -> String? {
            guard let range = path.range(of: marker) else { return nil }
            return path[range.upperBound...].split(separator: "/").first.map(String.init)
        }
        func program(for app: MigrationApp, key: String? = nil) -> AttributedProgram {
            let path = app.executablePath
            var category = AppCategory(rawValue: app.category) ?? .unclassified
            if category == .systemProcess, let path, !ProcessAttributor.isSystemExecutable(path) {
                category = .unclassified
            }
            if let key, !key.hasPrefix("exec:") {
                let name = key.hasPrefix("command:") ? String(key.dropFirst("command:".count)) : app.displayName
                return AttributedProgram(key: key, displayName: name, category: category, executablePath: path)
            }
            let source = key.map { String($0.dropFirst("exec:".count)) } ?? path
            if let source, let name = ExecutablePathNormalizer.programName(forExecutablePath: source) {
                return AttributedProgram(key: "command:\(name)", displayName: name, category: category, executablePath: path)
            }
            if let key {
                return AttributedProgram(key: key, displayName: app.displayName, category: category, executablePath: path)
            }
            if let path {
                return AttributedProgram(
                    key: "exec:\(ExecutablePathNormalizer.normalize(path))",
                    displayName: app.displayName,
                    category: category,
                    executablePath: path
                )
            }
            return AttributedProgram(key: "process:\(app.displayName)", displayName: app.displayName, category: category, executablePath: nil)
        }

        var plan: [String: HostProgramTarget] = [:]
        for app in apps {
            if app.appKey.hasPrefix("proxy:") || VirtualHost.isVirtual(app.appKey) { continue }

            if app.isApplication {
                // 附属应用归主应用，程序是它自己。
                if let bundleID = app.bundleID,
                   let mainBundleID = ProcessAttributor.auxiliaryApplicationHosts[bundleID],
                   appsByKey["bundle:\(mainBundleID)"] != nil {
                    plan[app.appKey] = HostProgramTarget(
                        hostKey: "bundle:\(mainBundleID)",
                        program: AttributedProgram(
                            key: app.appKey,
                            displayName: app.displayName,
                            category: .userApp,
                            executablePath: app.executablePath
                        )
                    )
                    continue
                }
                let ownPath = app.bundlePath ?? app.executablePath
                guard let ownPath, let outer = ProcessAttributor.outermostApplicationPath(in: ownPath + "/") else {
                    continue
                }
                // 嵌套在另一个应用里的 helper、扩展、小组件。
                if outer != app.bundlePath, let host = hostByPath[outer], host.appKey != app.appKey {
                    plan[app.appKey] = HostProgramTarget(hostKey: host.appKey, program: nil)
                    continue
                }
                guard !isHostPath(outer) else { continue }
                // 附属包、框架里的 `.app`：按程序处理；系统框架里的归「macOS 系统」。
                let hostKey = ProcessAttributor.isSystemExecutable(outer)
                    ? VirtualHost.systemKey
                    : directory(after: "/Library/Application Support/", in: outer)
                        .flatMap(owner(ofDirectory:))?.appKey ?? VirtualHost.otherKey
                plan[app.appKey] = HostProgramTarget(hostKey: hostKey, program: program(for: app))
                continue
            }

            // 命令行记录。
            let path = app.appKey.hasPrefix("exec:")
                ? String(app.appKey.dropFirst("exec:".count))
                : app.executablePath
            // 有路径时按路径判断：旧版本曾把 `/usr/bin/` 下的工具标成系统进程。
            let isSystem = path.map { ProcessAttributor.isSystemExecutable($0) }
                ?? (app.category == AppCategory.systemProcess.rawValue)
            if isSystem {
                plan[app.appKey] = HostProgramTarget(hostKey: VirtualHost.systemKey, program: program(for: app, key: app.appKey))
                continue
            }
            if let path, !path.contains(".app/") {
                let dataDirectory = directory(after: "/Library/Application Support/", in: path)
                    ?? directory(after: "/.cache/", in: path)
                if let host = dataDirectory.flatMap(owner(ofDirectory:)) {
                    plan[app.appKey] = HostProgramTarget(hostKey: host.appKey, program: nil)
                    continue
                }
                if let bundleID = editorExtensionDirectories.first(where: { path.contains($0.key) })?.value,
                   appsByKey["bundle:\(bundleID)"] != nil {
                    plan[app.appKey] = HostProgramTarget(hostKey: "bundle:\(bundleID)", program: program(for: app, key: app.appKey))
                    continue
                }
            }
            plan[app.appKey] = HostProgramTarget(hostKey: VirtualHost.otherKey, program: program(for: app, key: app.appKey))
        }
        return plan
    }

    private func loadMigrationApps() throws -> [MigrationApp] {
        var apps: [MigrationApp] = []
        let statement = try database.prepare(
            """
            SELECT app_key, bundle_path, executable_path, display_name, category, first_seen_at, last_seen_at
            FROM apps;
            """
        )
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteDatabaseError.stepFailed(database.errorMessage)
            }
            guard let appKey = database.columnString(statement, at: 0) else { continue }
            apps.append(MigrationApp(
                appKey: appKey,
                bundlePath: database.columnString(statement, at: 1),
                executablePath: database.columnString(statement, at: 2),
                displayName: database.columnString(statement, at: 3) ?? "",
                category: database.columnString(statement, at: 4) ?? AppCategory.unclassified.rawValue,
                firstSeenAt: database.columnString(statement, at: 5) ?? "0.000000",
                lastSeenAt: database.columnString(statement, at: 6) ?? "0.000000"
            ))
        }
        return apps
    }

    /// 版本 7：`exec:` appKey 改为归一化路径（版本号、哈希目录折叠成 `*`），
    /// 把同一工具各版本的历史行合并到新 appKey。所有口径一并合并，写入仍是累加。
    private func migrateVersionedExecutablePaths() throws {
        try database.execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var renames: [(oldKey: String, newKey: String, app: StoredApp, category: String)] = []
            let statement = try database.prepare(
                """
                SELECT app_key, bundle_id, bundle_path, executable_path, display_name,
                       category, first_seen_at, last_seen_at
                FROM apps
                WHERE app_key LIKE 'exec:%';
                """
            )
            defer { sqlite3_finalize(statement) }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw SQLiteDatabaseError.stepFailed(database.errorMessage)
                }
                guard let oldKey = database.columnString(statement, at: 0) else { continue }
                let path = String(oldKey.dropFirst("exec:".count))
                let newKey = "exec:\(ExecutablePathNormalizer.normalize(path))"
                guard newKey != oldKey else { continue }
                let displayName = ExecutablePathNormalizer.displayName(forExecutablePath: path)
                    ?? database.columnString(statement, at: 4)
                    ?? "未知进程"
                renames.append((
                    oldKey,
                    newKey,
                    StoredApp(
                        bundleID: database.columnString(statement, at: 1),
                        bundlePath: database.columnString(statement, at: 2),
                        executablePath: database.columnString(statement, at: 3),
                        displayName: displayName,
                        firstSeenAt: database.columnString(statement, at: 6) ?? "0.000000",
                        lastSeenAt: database.columnString(statement, at: 7) ?? "0.000000"
                    ),
                    database.columnString(statement, at: 5) ?? AppCategory.unclassified.rawValue
                ))
            }

            for rename in renames {
                try upsertRenamedApp(rename.app, appKey: rename.newKey, category: rename.category)
                try mergeUsageRows(in: "daily_usage", timeColumn: "day", from: rename.oldKey, to: rename.newKey)
                try mergeUsageRows(in: "usage_buckets", timeColumn: "bucket_start", from: rename.oldKey, to: rename.newKey)
                let deleteApp = try database.prepare("DELETE FROM apps WHERE app_key = ?;")
                defer { sqlite3_finalize(deleteApp) }
                try database.bind(rename.oldKey, at: 1, in: deleteApp)
                try database.stepDone(deleteApp)
            }
            try database.execute("PRAGMA user_version = 7;")
            try database.execute("COMMIT;")
        } catch {
            try? database.execute("ROLLBACK;")
            throw error
        }
    }

    /// 合并到同一新 appKey 的多行里，以最后出现的那行为准更新元数据。
    private func upsertRenamedApp(_ storedApp: StoredApp, appKey: String, category: String) throws {
        let statement = try database.prepare(
            """
            INSERT INTO apps (
                app_key, bundle_id, bundle_path, executable_path,
                display_name, category, first_seen_at, last_seen_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(app_key) DO UPDATE SET
                bundle_id = CASE WHEN excluded.last_seen_at >= apps.last_seen_at
                    THEN excluded.bundle_id ELSE apps.bundle_id END,
                bundle_path = CASE WHEN excluded.last_seen_at >= apps.last_seen_at
                    THEN excluded.bundle_path ELSE apps.bundle_path END,
                executable_path = CASE WHEN excluded.last_seen_at >= apps.last_seen_at
                    THEN excluded.executable_path ELSE apps.executable_path END,
                display_name = CASE WHEN excluded.last_seen_at >= apps.last_seen_at
                    THEN excluded.display_name ELSE apps.display_name END,
                category = CASE WHEN excluded.last_seen_at >= apps.last_seen_at
                    THEN excluded.category ELSE apps.category END,
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
        try database.bind(category, at: 6, in: statement)
        try database.bind(storedApp.firstSeenAt, at: 7, in: statement)
        try database.bind(storedApp.lastSeenAt, at: 8, in: statement)
        try database.stepDone(statement)
    }

    private func mergeUsageRows(
        in table: String,
        timeColumn: String,
        from oldAppKey: String,
        to newAppKey: String
    ) throws {
        let statement = try database.prepare(
            """
            INSERT INTO \(table) (
                accounting_version, \(timeColumn), app_key, download_bytes,
                upload_bytes, sample_count, updated_at
            )
            SELECT accounting_version, \(timeColumn), ?, download_bytes,
                   upload_bytes, sample_count, updated_at
            FROM \(table)
            WHERE app_key = ?
            ON CONFLICT(accounting_version, \(timeColumn), app_key) DO UPDATE SET
                download_bytes = \(table).download_bytes + excluded.download_bytes,
                upload_bytes = \(table).upload_bytes + excluded.upload_bytes,
                sample_count = \(table).sample_count + excluded.sample_count,
                updated_at = MAX(\(table).updated_at, excluded.updated_at);
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(newAppKey, at: 1, in: statement)
        try database.bind(oldAppKey, at: 2, in: statement)
        try database.stepDone(statement)
        try deleteRows(in: table, for: oldAppKey)
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

    private func prepareProgramUpsert() throws -> OpaquePointer {
        try database.prepare(
            """
            INSERT INTO programs (
                program_key, display_name, category, executable_path, first_seen_at, last_seen_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(program_key) DO UPDATE SET
                display_name = CASE WHEN excluded.last_seen_at >= programs.last_seen_at
                    THEN excluded.display_name ELSE programs.display_name END,
                category = CASE WHEN excluded.last_seen_at >= programs.last_seen_at
                    THEN excluded.category ELSE programs.category END,
                executable_path = CASE WHEN excluded.last_seen_at >= programs.last_seen_at
                    THEN COALESCE(excluded.executable_path, programs.executable_path)
                    ELSE programs.executable_path END,
                first_seen_at = MIN(programs.first_seen_at, excluded.first_seen_at),
                last_seen_at = MAX(programs.last_seen_at, excluded.last_seen_at);
            """
        )
    }

    private func upsertProgram(
        _ program: AttributedProgram,
        firstSeenAt: Date,
        lastSeenAt: Date,
        using statement: OpaquePointer
    ) throws {
        try database.bind(program.key, at: 1, in: statement)
        try database.bind(program.displayName, at: 2, in: statement)
        try database.bind(program.category.rawValue, at: 3, in: statement)
        try database.bind(program.executablePath, at: 4, in: statement)
        try database.bind(Self.timestamp(firstSeenAt), at: 5, in: statement)
        try database.bind(Self.timestamp(lastSeenAt), at: 6, in: statement)
        try database.stepDone(statement)
        try database.reset(statement)
    }

    private func prepareDailyUsageUpsert() throws -> OpaquePointer {
        try database.prepare(
            """
            INSERT INTO daily_usage (
                accounting_version, day, app_key, program_key, download_bytes,
                upload_bytes, sample_count, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accounting_version, day, app_key, program_key) DO UPDATE SET
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
                accounting_version, bucket_start, app_key, program_key, download_bytes,
                upload_bytes, sample_count, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accounting_version, bucket_start, app_key, program_key) DO UPDATE SET
                download_bytes = usage_buckets.download_bytes + excluded.download_bytes,
                upload_bytes = usage_buckets.upload_bytes + excluded.upload_bytes,
                sample_count = usage_buckets.sample_count + excluded.sample_count,
                updated_at = excluded.updated_at;
            """
        )
    }

    private func prepareRouteUsageUpsert() throws -> OpaquePointer {
        try database.prepare(
            """
            INSERT INTO daily_route_usage (
                accounting_version, day, app_key, program_key, route,
                download_bytes, upload_bytes, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accounting_version, day, app_key, program_key, route) DO UPDATE SET
                download_bytes = daily_route_usage.download_bytes + excluded.download_bytes,
                upload_bytes = daily_route_usage.upload_bytes + excluded.upload_bytes,
                updated_at = excluded.updated_at;
            """
        )
    }

    private func upsertRouteUsage(
        _ aggregate: RouteUsageAggregate,
        using statement: OpaquePointer
    ) throws {
        try database.bind(Self.accountingVersion, at: 1, in: statement)
        try database.bind(aggregate.day, at: 2, in: statement)
        try database.bind(aggregate.appKey, at: 3, in: statement)
        try database.bind(aggregate.programKey, at: 4, in: statement)
        try database.bind(aggregate.route.rawValue, at: 5, in: statement)
        try database.bind(aggregate.downloadBytes, at: 6, in: statement)
        try database.bind(aggregate.uploadBytes, at: 7, in: statement)
        try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 8, in: statement)
        try database.stepDone(statement)
        try database.reset(statement)
    }

    private func applyDomainUsage(_ aggregates: [DomainUsageAggregate]) throws {
        let statement = try database.prepare(
            """
            INSERT INTO daily_domain_usage (
                accounting_version, day, app_key, domain, route, download_bytes, upload_bytes, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(accounting_version, day, app_key, domain, route) DO UPDATE SET
                download_bytes = CASE
                    WHEN excluded.download_bytes > 9223372036854775807 - daily_domain_usage.download_bytes
                    THEN 9223372036854775807 ELSE daily_domain_usage.download_bytes + excluded.download_bytes END,
                upload_bytes = CASE
                    WHEN excluded.upload_bytes > 9223372036854775807 - daily_domain_usage.upload_bytes
                    THEN 9223372036854775807 ELSE daily_domain_usage.upload_bytes + excluded.upload_bytes END,
                updated_at = MAX(daily_domain_usage.updated_at, excluded.updated_at);
            """
        )
        defer { sqlite3_finalize(statement) }
        for aggregate in aggregates {
            try database.bind(Self.accountingVersion, at: 1, in: statement)
            try database.bind(aggregate.day, at: 2, in: statement)
            try database.bind(aggregate.appKey, at: 3, in: statement)
            try database.bind(aggregate.domain, at: 4, in: statement)
            try database.bind(aggregate.route.rawValue, at: 5, in: statement)
            try database.bind(aggregate.downloadBytes, at: 6, in: statement)
            try database.bind(aggregate.uploadBytes, at: 7, in: statement)
            try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 8, in: statement)
            try database.stepDone(statement)
            try database.reset(statement)
        }
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
        try database.bind(aggregate.programKey, at: 4, in: statement)
        try database.bind(aggregate.downloadBytes, at: 5, in: statement)
        try database.bind(aggregate.uploadBytes, at: 6, in: statement)
        try database.bind(aggregate.sampleCount, at: 7, in: statement)
        try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 8, in: statement)
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
        try database.bind(aggregate.programKey, at: 4, in: statement)
        try database.bind(aggregate.downloadBytes, at: 5, in: statement)
        try database.bind(aggregate.uploadBytes, at: 6, in: statement)
        try database.bind(aggregate.sampleCount, at: 7, in: statement)
        try database.bind(Self.timestamp(aggregate.lastSeenAt), at: 8, in: statement)
        try database.stepDone(statement)
        try database.reset(statement)
    }

    /// 子查询取 rowid 再删：`DELETE ... LIMIT` 需要 SQLite 开启
    /// `SQLITE_ENABLE_UPDATE_DELETE_LIMIT`，系统自带的 libsqlite3 并不保证编译了它。
    private func deleteBuckets(from table: String, before date: Date, limit: Int64) throws -> Int64 {
        let statement = try database.prepare(
            """
            DELETE FROM \(table)
            WHERE rowid IN (
                SELECT rowid FROM \(table) WHERE bucket_start < ? LIMIT ?
            );
            """
        )
        defer { sqlite3_finalize(statement) }

        try database.bind(Self.epochSeconds(date), at: 1, in: statement)
        try database.bind(limit, at: 2, in: statement)
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

    private static func dayString(for date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func dateValue(_ value: String?) -> Date {
        guard let value, let seconds = Double(value) else { return .distantPast }
        return Date(timeIntervalSince1970: seconds)
    }
}
