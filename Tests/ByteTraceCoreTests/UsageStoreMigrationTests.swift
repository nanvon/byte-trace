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
        let migratedDatabase = try SQLiteDatabase(url: url)
        try migratedDatabase.execute(
            """
            INSERT INTO daily_usage (
                accounting_version, day, app_key, download_bytes,
                upload_bytes, sample_count, updated_at
            ) VALUES (2, '2025-07-18', 'bundle:example.app', 50, 20, 1, '1754000000.000000');
            """
        )
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

        XCTAssertEqual(
            try migratedDatabase.scalarInt64(
                "SELECT download_bytes FROM daily_usage WHERE accounting_version = 1 AND app_key = 'bundle:example.app';"
            ),
            100
        )
        XCTAssertEqual(
            try migratedDatabase.scalarInt64(
                "SELECT download_bytes FROM daily_usage WHERE accounting_version = 2 AND app_key = 'bundle:example.app';"
            ),
            50
        )
        XCTAssertEqual(
            try migratedDatabase.scalarInt64(
                "SELECT download_bytes FROM daily_usage WHERE accounting_version = \(UsageStore.accountingVersion) AND app_key = 'bundle:example.app';"
            ),
            7
        )
    }

    func testVersionedExecutableKeysMergeIntoNormalizedKey() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-exec-normalize-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        let database = try SQLiteDatabase(url: url)
        try createVersionFiveTables(in: database)
        try database.execute(
            """
            INSERT INTO apps VALUES (
                'exec:/Users/u/.local/share/claude/versions/2.1.300', NULL, NULL,
                '/Users/u/.local/share/claude/versions/2.1.300', '2.1.300',
                'unclassified', '1754000000.000000', '1754000000.000000'
            );
            INSERT INTO apps VALUES (
                'exec:/Users/u/.local/share/claude/versions/2.1.314', NULL, NULL,
                '/Users/u/.local/share/claude/versions/2.1.314', '2.1.314',
                'unclassified', '1754000100.000000', '1754000200.000000'
            );
            INSERT INTO apps VALUES (
                'exec:/usr/bin/curl', NULL, NULL, '/usr/bin/curl', 'curl',
                'system_process', '1754000000.000000', '1754000000.000000'
            );
            INSERT INTO daily_usage VALUES ('2025-07-18', 'exec:/Users/u/.local/share/claude/versions/2.1.300', 10, 1, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'exec:/Users/u/.local/share/claude/versions/2.1.314', 20, 2, 2, '1754000200.000000');
            INSERT INTO daily_usage VALUES ('2025-07-19', 'exec:/Users/u/.local/share/claude/versions/2.1.314', 5, 0, 1, '1754086400.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'exec:/usr/bin/curl', 7, 7, 1, '1754000000.000000');
            INSERT INTO usage_buckets VALUES (1754000000, 'exec:/Users/u/.local/share/claude/versions/2.1.300', 10, 1, 1, '1754000000.000000');
            INSERT INTO usage_buckets VALUES (1754000000, 'exec:/Users/u/.local/share/claude/versions/2.1.314', 20, 2, 2, '1754000200.000000');
            PRAGMA user_version = 5;
            """
        )

        _ = try UsageStore(databaseURL: url)
        let migrated = try SQLiteDatabase(url: url)
        let key = "exec:/Users/u/.local/share/claude/versions/*"
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT COUNT(*) FROM apps WHERE app_key LIKE 'exec:/Users/u/.local/share/claude/%';"),
            1
        )
        XCTAssertEqual(
            try migrated.scalarInt64(
                "SELECT COUNT(*) FROM apps WHERE app_key = '\(key)' AND display_name = 'claude' AND executable_path LIKE '%2.1.314' AND first_seen_at = '1754000000.000000';"
            ),
            1
        )
        XCTAssertEqual(
            try migrated.scalarInt64(
                "SELECT download_bytes FROM daily_usage WHERE app_key = '\(key)' AND day = '2025-07-18';"
            ),
            30
        )
        XCTAssertEqual(
            try migrated.scalarInt64(
                "SELECT sample_count FROM daily_usage WHERE app_key = '\(key)' AND day = '2025-07-18';"
            ),
            3
        )
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT COUNT(*) FROM daily_usage WHERE app_key = '\(key)';"),
            2
        )
        XCTAssertEqual(
            try migrated.scalarInt64(
                "SELECT upload_bytes FROM usage_buckets WHERE app_key = '\(key)' AND bucket_start = 1754000000;"
            ),
            3
        )
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT download_bytes FROM daily_usage WHERE app_key = 'command:curl';"),
            7
        )
        XCTAssertEqual(try migrated.scalarInt64("PRAGMA user_version;"), UsageStore.schemaVersion)
    }

    func testHostApplicationKeysMergeOnlyWhenTheHostIsCertain() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-host-merge-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        let database = try SQLiteDatabase(url: url)
        try createVersionFiveTables(in: database)
        let support = "/Users/u/Library/Application Support"
        try database.execute(
            """
            INSERT INTO apps VALUES ('bundle:com.example.host', 'com.example.host', '/Applications/Host.app', '/Applications/Host.app/Contents/MacOS/Host', 'Host', 'user_app', '1754000100.000000', '1754000100.000000');
            INSERT INTO apps VALUES ('bundle:com.example.host.updater', 'com.example.host.updater', '/Applications/Host.app/Contents/Library/Updater.app', '/Applications/Host.app/Contents/Library/Updater.app/Contents/MacOS/Updater', 'Updater', 'user_app', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('bundle:com.anthropic.claudefordesktop', 'com.anthropic.claudefordesktop', '/Applications/Claude.app', '/Applications/Claude.app/Contents/MacOS/Claude', 'Claude', 'user_app', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('bundle:com.anthropic.claude-code', 'com.anthropic.claude-code', '\(support)/Claude/claude-code/2.1/abc/claude.app', '\(support)/Claude/claude-code/2.1/abc/claude.app/Contents/MacOS/claude', 'Claude Code', 'user_app', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('bundle:com.google.GoogleUpdater', 'com.google.GoogleUpdater', '\(support)/Google/GoogleUpdater/1.0/GoogleUpdater.app', '\(support)/Google/GoogleUpdater/1.0/GoogleUpdater.app/Contents/MacOS/GoogleUpdater', 'GoogleUpdater', 'user_app', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('bundle:com.yetone.magpie', 'com.yetone.magpie', '/Applications/magpie.app', '/Applications/magpie.app/Contents/MacOS/magpie', 'magpie', 'user_app', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('exec:/usr/bin/curl', NULL, NULL, '/usr/bin/curl', 'curl', 'system_process', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('exec:/opt/homebrew/Cellar/curl/*/bin/curl', NULL, NULL, '/opt/homebrew/Cellar/curl/8.0/bin/curl', 'curl', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('exec:/Users/u/.local/share/claude/versions/*', NULL, NULL, '/Users/u/.local/share/claude/versions/2.1.300', 'claude', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('process:magpie', NULL, NULL, NULL, 'magpie', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('process:Updater', NULL, NULL, NULL, 'Updater', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('process:curl', NULL, NULL, NULL, 'curl', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('process:2.1.314', NULL, NULL, NULL, '2.1.314', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'bundle:com.example.host', 100, 10, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'bundle:com.example.host.updater', 20, 2, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'process:Updater', 3, 0, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'bundle:com.anthropic.claudefordesktop', 50, 5, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'bundle:com.anthropic.claude-code', 70, 7, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'bundle:com.google.GoogleUpdater', 9, 0, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'bundle:com.yetone.magpie', 40, 4, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'process:magpie', 6, 1, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'process:curl', 8, 0, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'exec:/Users/u/.local/share/claude/versions/*', 30, 3, 1, '1754000000.000000');
            INSERT INTO daily_usage VALUES ('2025-07-18', 'process:2.1.314', 2, 0, 1, '1754000000.000000');
            INSERT INTO usage_buckets VALUES (1754000000, 'bundle:com.anthropic.claude-code', 70, 7, 1, '1754000000.000000');
            PRAGMA user_version = 5;
            """
        )

        _ = try UsageStore(databaseURL: url)
        let migrated = try SQLiteDatabase(url: url)
        func download(_ appKey: String) throws -> Int64 {
            try migrated.scalarInt64(
                "SELECT COALESCE(SUM(download_bytes), -1) FROM daily_usage WHERE app_key = '\(appKey)';"
            )
        }
        func appCount(_ appKey: String) throws -> Int64 {
            try migrated.scalarInt64("SELECT COUNT(*) FROM apps WHERE app_key = '\(appKey)';")
        }

        XCTAssertEqual(try download("bundle:com.example.host"), 123)
        XCTAssertEqual(try appCount("bundle:com.example.host.updater"), 0)
        XCTAssertEqual(try appCount("process:Updater"), 0)
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT COUNT(*) FROM apps WHERE app_key = 'bundle:com.example.host' AND first_seen_at = '1754000000.000000';"),
            1
        )
        XCTAssertEqual(try download("bundle:com.anthropic.claudefordesktop"), 120)
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT download_bytes FROM usage_buckets WHERE app_key = 'bundle:com.anthropic.claudefordesktop';"),
            70
        )
        XCTAssertEqual(try download("bundle:com.google.GoogleUpdater"), 9)
        XCTAssertEqual(try download("bundle:com.yetone.magpie"), 46)
        XCTAssertEqual(try download("exec:/Users/u/.local/share/claude/versions/*"), 32)
        // 两个 curl 按名称合并成一条后，解析前就退出的 process:curl 也能确定归属。
        XCTAssertEqual(try download("process:curl"), -1)
        XCTAssertEqual(try download("command:curl"), 8)
        XCTAssertEqual(try appCount("exec:/usr/bin/curl"), 0)
        XCTAssertEqual(try appCount("exec:/opt/homebrew/Cellar/curl/*/bin/curl"), 0)
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT SUM(download_bytes) FROM daily_usage;"),
            338
        )
        XCTAssertEqual(try migrated.scalarInt64("PRAGMA user_version;"), UsageStore.schemaVersion)
    }

    func testRecordsWrittenAfterVersionTenMergeOnNextOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-late-merge-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        _ = try UsageStore(databaseURL: url)
        let database = try SQLiteDatabase(url: url)
        try database.execute(
            """
            INSERT INTO apps VALUES ('bundle:org.python.python', 'org.python.python', '/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app', '/Library/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python', 'Python', 'user_app', '1754000100.000000', '1754000100.000000');
            INSERT INTO apps VALUES ('exec:/usr/bin/curl', NULL, NULL, '/usr/bin/curl', 'curl', 'system_process', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('exec:/opt/homebrew/Cellar/curl/*/bin/curl', NULL, NULL, '/opt/homebrew/Cellar/curl/8.0/bin/curl', 'curl', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('process:Python', NULL, NULL, NULL, 'Python', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('process:curl', NULL, NULL, NULL, 'curl', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'bundle:org.python.python', 100, 10, 1, '1754000100.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'process:Python', 7, 1, 1, '1754000000.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'process:curl', 5, 0, 1, '1754000000.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'exec:/usr/bin/curl', 20, 1, 1, '1754000000.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'exec:/opt/homebrew/Cellar/curl/*/bin/curl', 30, 2, 1, '1754000000.000000');
            INSERT INTO app_launchers VALUES ('exec:/usr/bin/curl', 'opencode', '1754000200.000000');
            INSERT INTO app_launchers VALUES ('exec:/opt/homebrew/Cellar/curl/*/bin/curl', 'ruby', '1754000100.000000');
            """
        )

        // 打开两次：第二次没有可合并的记录，字节不能重复累加。
        _ = try UsageStore(databaseURL: url)
        _ = try UsageStore(databaseURL: url)

        func download(_ appKey: String) throws -> Int64 {
            try database.scalarInt64(
                "SELECT COALESCE(SUM(download_bytes), -1) FROM daily_usage WHERE app_key = '\(appKey)';"
            )
        }
        XCTAssertEqual(try download("bundle:org.python.python"), 107)
        XCTAssertEqual(try download("process:Python"), -1)
        XCTAssertEqual(try database.scalarInt64("SELECT COUNT(*) FROM apps WHERE app_key = 'process:Python';"), 0)
        // 系统自带与 Homebrew 的 curl 按名称合并，process:curl 随之并入；不再算系统进程。
        XCTAssertEqual(try download("process:curl"), -1)
        XCTAssertEqual(try download("command:curl"), 55)
        XCTAssertEqual(try database.scalarInt64("SELECT COUNT(*) FROM apps WHERE display_name = 'curl';"), 1)
        XCTAssertEqual(
            try database.scalarInt64("SELECT COUNT(*) FROM apps WHERE app_key = 'command:curl' AND category = 'unclassified';"),
            1
        )
        XCTAssertEqual(
            try database.scalarInt64("SELECT COUNT(*) FROM app_launchers WHERE app_key = 'command:curl' AND launcher_name = 'opencode';"),
            1
        )
        XCTAssertEqual(try database.scalarInt64("SELECT COUNT(*) FROM app_launchers;"), 1)
        XCTAssertEqual(try database.scalarInt64("PRAGMA user_version;"), UsageStore.schemaVersion)
    }

    func testBundledToolsMergeIntoTheApplicationOwningTheirDirectory() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-tool-merge-\(UUID().uuidString).sqlite3")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + "-wal")
            try? FileManager.default.removeItem(atPath: url.path + "-shm")
        }

        _ = try UsageStore(databaseURL: url)
        let database = try SQLiteDatabase(url: url)
        let support = "/Users/u/Library/Application Support"
        try database.execute(
            """
            INSERT INTO apps VALUES ('bundle:com.raycast.macos', 'com.raycast.macos', '/Applications/Raycast.app', '/Applications/Raycast.app/Contents/MacOS/Raycast', 'Raycast', 'user_app', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('bundle:com.yetone.magpie', 'com.yetone.magpie', '/Applications/magpie.app', '/Applications/magpie.app/Contents/MacOS/magpie', 'magpie', 'user_app', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('bundle:com.microsoft.VSCode', 'com.microsoft.VSCode', '/Applications/Visual Studio Code.app', '/Applications/Visual Studio Code.app/Contents/MacOS/Code', 'Code', 'user_app', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('exec:\(support)/com.raycast.macos/node/runtime/node-*-darwin-arm64/bin/node', NULL, NULL, '\(support)/com.raycast.macos/node/runtime/node-v22-darwin-arm64/bin/node', 'node', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('exec:/Users/u/.cache/magpie/bun/*/magpie-bun', NULL, NULL, '/Users/u/.cache/magpie/bun/1.2/magpie-bun', 'magpie-bun', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('exec:/var/folders/x/T/magpie-preview-1/.cache/magpie/bun/*/magpie-bun', NULL, NULL, '/var/folders/x/T/magpie-preview-1/.cache/magpie/bun/1.2/magpie-bun', 'magpie-bun', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO apps VALUES ('exec:\(support)/Code/agent-host/claude', NULL, NULL, '\(support)/Code/agent-host/claude', 'claude', 'unclassified', '1754000000.000000', '1754000000.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'bundle:com.raycast.macos', 10, 0, 1, '1754000000.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'exec:\(support)/com.raycast.macos/node/runtime/node-*-darwin-arm64/bin/node', 5, 0, 1, '1754000000.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'exec:/Users/u/.cache/magpie/bun/*/magpie-bun', 7, 0, 1, '1754000000.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'exec:/var/folders/x/T/magpie-preview-1/.cache/magpie/bun/*/magpie-bun', 2, 0, 1, '1754000000.000000');
            INSERT INTO daily_usage (accounting_version, day, app_key, download_bytes, upload_bytes, sample_count, updated_at)
                VALUES (3, '2026-11-08', 'exec:\(support)/Code/agent-host/claude', 3, 0, 1, '1754000000.000000');
            """
        )

        _ = try UsageStore(databaseURL: url)

        func download(_ appKey: String) throws -> Int64 {
            try database.scalarInt64(
                "SELECT COALESCE(SUM(download_bytes), -1) FROM daily_usage WHERE app_key = '\(appKey)';"
            )
        }
        XCTAssertEqual(try download("bundle:com.raycast.macos"), 15)
        XCTAssertEqual(try download("bundle:com.yetone.magpie"), 9)
        // Application Support 下只认 bundle ID 目录，按应用名的目录不合并。
        XCTAssertEqual(try download("exec:\(support)/Code/agent-host/claude"), 3)
        XCTAssertEqual(try download("bundle:com.microsoft.VSCode"), -1)
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
