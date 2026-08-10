import Foundation
import XCTest

@testable import ByteTraceCore

final class UsageStoreMigrationTests: XCTestCase {
    func testLegacyCCBarUsageMovesToTheApplicationKey() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-migration-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        let sampleDate = Date(timeIntervalSince1970: 1_754_000_000)
        try seedLegacyCCBarUsage(at: url, sampleDate: sampleDate)

        let store = try UsageStore(databaseURL: url)
        XCTAssertTrue(try store.dailyUsage(for: "2025-07-18").isEmpty)

        let migrated = try SQLiteDatabase(url: url)
        XCTAssertEqual(
            try migrated.scalarInt64(
                "SELECT COUNT(*) FROM apps WHERE app_key = 'bundle:com.nanvon.ccbar' AND category = 'user_app';"
            ),
            1
        )
        XCTAssertEqual(
            try migrated.scalarInt64(
                "SELECT COUNT(*) FROM daily_usage WHERE accounting_version = 1 AND app_key = 'bundle:com.nanvon.ccbar' AND download_bytes = 10 AND upload_bytes = 4;"
            ),
            1
        )
        XCTAssertEqual(
            try migrated.scalarInt64(
                "SELECT COUNT(*) FROM usage_buckets WHERE accounting_version = 1 AND app_key = 'bundle:com.nanvon.ccbar';"
            ),
            1
        )
    }

    func testPreviousSchemaDropsRetiredHostUsageTable() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-host-retirement-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        let database = try SQLiteDatabase(url: url)
        try createVersionFiveTables(in: database)
        try database.execute(
            """
            CREATE TABLE host_usage_buckets (bucket_start INTEGER PRIMARY KEY);
            PRAGMA user_version = 4;
            """
        )

        _ = try UsageStore(databaseURL: url)

        let migratedDatabase = try SQLiteDatabase(url: url)
        XCTAssertEqual(
            try migratedDatabase.scalarInt64(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'host_usage_buckets';"
            ),
            0
        )
        XCTAssertEqual(
            try migratedDatabase.scalarInt64("PRAGMA user_version;"),
            UsageStore.schemaVersion
        )
    }

    func testVersionFiveUsageIsPreservedButNotMixedWithCurrentAccounting() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-accounting-version-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        try seedVersionFiveUsage(at: url)
        let store = try UsageStore(databaseURL: url)
        XCTAssertTrue(try store.dailyUsage(for: "2025-07-18").isEmpty)

        let sampleDate = Date(timeIntervalSince1970: 1_754_000_000)
        try store.apply(
            [
                DailyUsageAggregate(
                    day: "2025-07-18",
                    appKey: "bundle:example.app",
                    displayName: "示例应用",
                    category: .userApp,
                    bundleID: "example.app",
                    bundlePath: nil,
                    executablePath: nil,
                    firstSeenAt: sampleDate,
                    lastSeenAt: sampleDate,
                    downloadBytes: 7,
                    uploadBytes: 3,
                    sampleCount: 1
                )
            ]
        )

        let current = try store.dailyUsage(for: "2025-07-18")
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].downloadBytes, 7)
        XCTAssertEqual(current[0].uploadBytes, 3)

        let database = try SQLiteDatabase(url: url)
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT download_bytes FROM daily_usage WHERE accounting_version = 1 AND app_key = 'bundle:example.app';"
            ),
            100
        )
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT download_bytes FROM daily_usage WHERE accounting_version = 2 AND app_key = 'bundle:example.app';"
            ),
            7
        )
    }

    private func seedLegacyCCBarUsage(at url: URL, sampleDate: Date) throws {
        let database = try SQLiteDatabase(url: url)
        try createVersionFiveTables(in: database)
        try database.execute(
            """
            INSERT INTO apps VALUES (
                'proxy:ccbar', 'com.nanvon.ccbar', '/Applications/CCBar.app',
                '/Applications/CCBar.app/Contents/MacOS/CCBar', 'CCBar',
                'proxy_transport', '1754000000.000000', '1754000000.000000'
            );
            INSERT INTO daily_usage VALUES ('2025-07-18', 'proxy:ccbar', 10, 4, 1, '1754000000.000000');
            INSERT INTO usage_buckets VALUES (
                \(Int64(sampleDate.timeIntervalSince1970)), 'proxy:ccbar', 10, 4, 1, '1754000000.000000'
            );
            PRAGMA user_version = 3;
            """
        )
    }

    private func seedVersionFiveUsage(at url: URL) throws {
        let database = try SQLiteDatabase(url: url)
        try createVersionFiveTables(in: database)
        try database.execute(
            """
            INSERT INTO apps VALUES (
                'bundle:example.app', 'example.app', NULL, NULL, '示例应用',
                'user_app', '1754000000.000000', '1754000000.000000'
            );
            INSERT INTO daily_usage VALUES (
                '2025-07-18', 'bundle:example.app', 100, 40, 1, '1754000000.000000'
            );
            INSERT INTO usage_buckets VALUES (
                1754000000, 'bundle:example.app', 100, 40, 1, '1754000000.000000'
            );
            PRAGMA user_version = 5;
            """
        )
    }

    private func createVersionFiveTables(in database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE apps (
                app_key TEXT PRIMARY KEY,
                bundle_id TEXT,
                bundle_path TEXT,
                executable_path TEXT,
                display_name TEXT NOT NULL,
                category TEXT NOT NULL,
                first_seen_at TEXT NOT NULL,
                last_seen_at TEXT NOT NULL
            );
            CREATE TABLE daily_usage (
                day TEXT NOT NULL,
                app_key TEXT NOT NULL,
                download_bytes INTEGER NOT NULL DEFAULT 0,
                upload_bytes INTEGER NOT NULL DEFAULT 0,
                sample_count INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (day, app_key),
                FOREIGN KEY (app_key) REFERENCES apps(app_key)
            );
            CREATE TABLE usage_buckets (
                bucket_start INTEGER NOT NULL,
                app_key TEXT NOT NULL,
                download_bytes INTEGER NOT NULL DEFAULT 0,
                upload_bytes INTEGER NOT NULL DEFAULT 0,
                sample_count INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (bucket_start, app_key),
                FOREIGN KEY (app_key) REFERENCES apps(app_key)
            );
            CREATE INDEX idx_usage_buckets_start ON usage_buckets(bucket_start);
            CREATE TABLE collector_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                occurred_at TEXT NOT NULL,
                kind TEXT NOT NULL,
                details TEXT
            );
            """
        )
    }
}
