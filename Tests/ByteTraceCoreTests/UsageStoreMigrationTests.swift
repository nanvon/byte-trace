import Foundation
import SQLite3
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
        let url = temporaryDatabaseURL("exec-normalize")
        defer { removeDatabase(at: url) }

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
        // 版本目录先归一成 exec:…/versions/*，版本 12 再按工具名记为程序 command:claude，宿主未知归「命令行工具」。
        let where_ = "app_key = 'host:other' AND program_key = 'command:claude'"
        XCTAssertEqual(try migrated.scalarInt64("SELECT COUNT(*) FROM apps WHERE app_key LIKE 'exec:%';"), 0)
        XCTAssertEqual(
            try migrated.scalarInt64(
                "SELECT COUNT(*) FROM programs WHERE program_key = 'command:claude' AND display_name = 'claude' AND executable_path LIKE '%2.1.314' AND first_seen_at = '1754000000.000000';"
            ),
            1
        )
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT download_bytes FROM daily_usage WHERE \(where_) AND day = '2025-07-18';"),
            30
        )
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT sample_count FROM daily_usage WHERE \(where_) AND day = '2025-07-18';"),
            3
        )
        XCTAssertEqual(try migrated.scalarInt64("SELECT COUNT(*) FROM daily_usage WHERE \(where_);"), 2)
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT upload_bytes FROM usage_buckets WHERE \(where_) AND bucket_start = 1754000000;"),
            3
        )
        // `/usr/bin/` 下的工具不算系统进程，即使旧版本这样标过。
        XCTAssertEqual(
            try migrated.scalarInt64(
                "SELECT download_bytes FROM daily_usage WHERE app_key = 'host:other' AND program_key = 'command:curl';"
            ),
            7
        )
        XCTAssertEqual(
            try migrated.scalarInt64("SELECT COUNT(*) FROM programs WHERE program_key = 'command:curl' AND category = 'unclassified';"),
            1
        )
        XCTAssertEqual(try migrated.scalarInt64("PRAGMA user_version;"), UsageStore.schemaVersion)
    }

    func testVersionTwelveMovesRecordsUnderHostsAndPrograms() throws {
        let url = temporaryDatabaseURL("v12-hosts")
        defer { removeDatabase(at: url) }

        let database = try SQLiteDatabase(url: url)
        try createVersionElevenTables(in: database)
        let support = "/Users/u/Library/Application Support"
        let python = "/opt/homebrew/Cellar/python@3.13/3.13.0/Frameworks/Python.framework/Versions/3.13/Resources/Python.app"
        let rows: [(key: String, bundleID: String?, bundlePath: String?, exe: String?, name: String, category: String, bytes: Int64)] = [
            ("bundle:com.example.host", "com.example.host", "/Applications/Host.app", "/Applications/Host.app/Contents/MacOS/Host", "Host", "user_app", 1),
            ("bundle:com.example.host.updater", "com.example.host.updater", "/Applications/Host.app/Contents/Library/Updater.app", "/Applications/Host.app/Contents/Library/Updater.app/Contents/MacOS/Updater", "Updater", "user_app", 2),
            ("bundle:com.anthropic.claudefordesktop", "com.anthropic.claudefordesktop", "/Applications/Claude.app", "/Applications/Claude.app/Contents/MacOS/Claude", "Claude", "user_app", 4),
            ("bundle:com.anthropic.claude-code", "com.anthropic.claude-code", "\(support)/Claude/claude-code/2.1/abc/claude.app", "\(support)/Claude/claude-code/2.1/abc/claude.app/Contents/MacOS/claude", "Claude Code", "user_app", 8),
            ("bundle:com.google.Chrome", "com.google.Chrome", "/Applications/Google Chrome.app", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "Google Chrome", "user_app", 16),
            ("bundle:com.google.GoogleUpdater", "com.google.GoogleUpdater", "\(support)/Google/GoogleUpdater/1.0/GoogleUpdater.app", "\(support)/Google/GoogleUpdater/1.0/GoogleUpdater.app/Contents/MacOS/GoogleUpdater", "GoogleUpdater", "user_app", 32),
            ("bundle:org.python.python", "org.python.python", python, "\(python)/Contents/MacOS/Python", "Python", "user_app", 64),
            ("bundle:com.yetone.magpie", "com.yetone.magpie", "/Applications/magpie.app", "/Applications/magpie.app/Contents/MacOS/magpie", "magpie", "user_app", 128),
            ("bundle:com.microsoft.VSCode", "com.microsoft.VSCode", "/Applications/Visual Studio Code.app", "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", "Code", "user_app", 256),
            ("command:curl", nil, nil, "/usr/bin/curl", "curl", "unclassified", 512),
            ("command:mDNSResponder", nil, nil, "/usr/sbin/mDNSResponder", "mDNSResponder", "system_process", 1024),
            ("exec:/usr/libexec/nsurlsessiond", nil, nil, "/usr/libexec/nsurlsessiond", "nsurlsessiond", "system_process", 2048),
            ("exec:/Users/u/.cache/magpie/bin/magpie-bun", nil, nil, "/Users/u/.cache/magpie/bin/magpie-bun", "magpie-bun", "unclassified", 4096),
            ("exec:/Users/u/.vscode/extensions/ms-python.python-*/dist/lsp-server", nil, nil, "/Users/u/.vscode/extensions/ms-python.python-2026.1.0/dist/lsp-server", "lsp-server", "unclassified", 8192),
            ("process:orphan", nil, nil, nil, "orphan", "unclassified", 16384),
            ("proxy:mihomo", nil, nil, "/opt/homebrew/bin/mihomo", "mihomo", "proxy_transport", 32768)
        ]
        for row in rows {
            let insertApp = try database.prepare("INSERT INTO apps VALUES (?, ?, ?, ?, ?, ?, '100.000000', '200.000000');")
            try database.bind(row.key, at: 1, in: insertApp)
            try database.bind(row.bundleID, at: 2, in: insertApp)
            try database.bind(row.bundlePath, at: 3, in: insertApp)
            try database.bind(row.exe, at: 4, in: insertApp)
            try database.bind(row.name, at: 5, in: insertApp)
            try database.bind(row.category, at: 6, in: insertApp)
            try database.stepDone(insertApp)
            sqlite3_finalize(insertApp)

            let insertUsage = try database.prepare(
                "INSERT INTO daily_usage VALUES (3, '2026-11-08', ?, ?, 0, 1, '100.000000');"
            )
            try database.bind(row.key, at: 1, in: insertUsage)
            try database.bind(row.bytes, at: 2, in: insertUsage)
            try database.stepDone(insertUsage)
            sqlite3_finalize(insertUsage)
        }
        try database.execute(
            """
            INSERT INTO usage_buckets VALUES (3, 1762560000, 'bundle:com.anthropic.claude-code', 8, 0, 1, '100.000000');
            INSERT INTO usage_buckets VALUES (3, 1762560000, 'bundle:com.anthropic.claudefordesktop', 4, 0, 1, '100.000000');
            INSERT INTO daily_route_usage VALUES (3, '2026-11-08', 'command:curl', 'proxied', 500, 0, '100.000000');
            INSERT INTO daily_route_usage VALUES (3, '2026-11-08', 'bundle:com.example.host.updater', 'direct', 2, 0, '100.000000');
            INSERT INTO daily_route_usage VALUES (3, '2026-11-08', 'bundle:com.example.host', 'direct', 1, 0, '100.000000');
            INSERT INTO app_launchers VALUES ('command:curl', 'opencode', '100.000000');
            INSERT INTO process_names VALUES ('curl', 'command:curl', '100.000000');
            INSERT INTO process_names VALUES ('Updater', 'bundle:com.example.host.updater', '100.000000');
            PRAGMA user_version = 11;
            """
        )

        _ = try UsageStore(databaseURL: url)
        _ = try UsageStore(databaseURL: url)

        func download(_ appKey: String, _ programKey: String = "") throws -> Int64 {
            try database.scalarInt64(
                "SELECT COALESCE(SUM(download_bytes), -1) FROM daily_usage WHERE app_key = '\(appKey)' AND program_key = '\(programKey)';"
            )
        }
        func appCount(_ appKey: String) throws -> Int64 {
            try database.scalarInt64("SELECT COUNT(*) FROM apps WHERE app_key = '\(appKey)';")
        }

        // 嵌套在应用里的 helper 归外层应用，算应用自身。
        XCTAssertEqual(try download("bundle:com.example.host"), 1 + 2)
        XCTAssertEqual(try appCount("bundle:com.example.host.updater"), 0)
        // Application Support 下的附属包归到目录名对应的应用，作为它的程序。
        XCTAssertEqual(try download("bundle:com.anthropic.claudefordesktop"), 4)
        XCTAssertEqual(try download("bundle:com.anthropic.claudefordesktop", "command:claude"), 8)
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT download_bytes FROM usage_buckets WHERE app_key = 'bundle:com.anthropic.claudefordesktop' AND program_key = 'command:claude';"
            ),
            8
        )
        // 附属应用归主应用，程序是它自己。
        XCTAssertEqual(try download("bundle:com.google.Chrome", "bundle:com.google.GoogleUpdater"), 32)
        XCTAssertEqual(try appCount("bundle:com.google.GoogleUpdater"), 0)
        // 框架里的 Python.app 不是应用，是程序。
        XCTAssertEqual(try download("host:other", "command:python"), 64)
        // 应用数据目录与编辑器扩展目录里的工具归对应应用。
        XCTAssertEqual(try download("bundle:com.yetone.magpie"), 128 + 4096)
        XCTAssertEqual(try download("bundle:com.microsoft.VSCode", "command:lsp-server"), 8192)
        // 系统目录归「macOS 系统」；其余命令行记录没有记下宿主，归「命令行工具」。
        XCTAssertEqual(try download("host:system", "command:mDNSResponder"), 1024)
        XCTAssertEqual(try download("host:system", "exec:/usr/libexec/nsurlsessiond"), 2048)
        XCTAssertEqual(try download("host:other", "command:curl"), 512)
        XCTAssertEqual(try download("host:other", "process:orphan"), 16384)
        XCTAssertEqual(try download("proxy:mihomo"), 32768)
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT COUNT(*) FROM apps WHERE app_key = 'host:other' AND display_name = '命令行工具' AND category = 'unclassified';"
            ),
            1
        )
        XCTAssertEqual(
            try database.scalarInt64("SELECT COUNT(*) FROM apps WHERE app_key = 'host:system' AND category = 'system_process';"),
            1
        )
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT COUNT(*) FROM apps WHERE app_key LIKE 'command:%' OR app_key LIKE 'exec:%' OR app_key LIKE 'process:%';"
            ),
            0
        )

        // 路径表跟着搬，同一位置的行合并。
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT download_bytes FROM daily_route_usage WHERE app_key = 'host:other' AND program_key = 'command:curl' AND route = 'proxied';"
            ),
            500
        )
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT download_bytes FROM daily_route_usage WHERE app_key = 'bundle:com.example.host' AND program_key = '' AND route = 'direct';"
            ),
            3
        )

        // 进程名映射改到新位置，启动者表删除。
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT COUNT(*) FROM process_names WHERE process_name = 'curl' AND app_key = 'host:other' AND program_key = 'command:curl';"
            ),
            1
        )
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT COUNT(*) FROM process_names WHERE process_name = 'Updater' AND app_key = 'bundle:com.example.host' AND program_key = '';"
            ),
            1
        )
        XCTAssertEqual(
            try database.scalarInt64("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'app_launchers';"),
            0
        )
        XCTAssertEqual(
            try database.scalarInt64("SELECT SUM(download_bytes) FROM daily_usage;"),
            rows.reduce(0) { $0 + $1.bytes }
        )
        XCTAssertEqual(try database.scalarInt64("PRAGMA user_version;"), UsageStore.schemaVersion)
    }

    func testVersionThirteenMergesLegacyHostIntoCommandLineTools() throws {
        let url = temporaryDatabaseURL("v13-legacy")
        defer { removeDatabase(at: url) }

        _ = try UsageStore(databaseURL: url)
        let database = try SQLiteDatabase(url: url)
        let agent = "/System/Library/PrivateFrameworks/IMTransferServices.framework/IMTransferAgent.app/Contents/MacOS/IMTransferAgent"
        try database.execute(
            """
            INSERT INTO apps VALUES ('host:legacy', NULL, NULL, NULL, '历史记录（未区分来源）', 'unclassified', '1750000000.000000', '1780000000.000000');
            INSERT INTO apps VALUES ('host:other', NULL, NULL, NULL, '其他程序', 'unclassified', '1760000000.000000', '1770000000.000000');
            INSERT INTO programs VALUES ('command:curl', 'curl', 'unclassified', '/usr/bin/curl', '1750000000.000000', '1780000000.000000');
            INSERT INTO programs VALUES ('exec:\(agent)', 'IMTransferAgent', 'system_process', NULL, '1750000000.000000', '1780000000.000000');
            INSERT INTO daily_usage VALUES (3, '2026-11-08', 'host:legacy', 'command:curl', 10, 1, 1, '100.000000');
            INSERT INTO daily_usage VALUES (3, '2026-11-08', 'host:other', 'command:curl', 5, 2, 1, '200.000000');
            INSERT INTO daily_usage VALUES (3, '2026-11-08', 'host:legacy', 'exec:\(agent)', 7, 0, 1, '100.000000');
            INSERT INTO usage_buckets VALUES (3, 1762560000, 'host:legacy', 'command:curl', 10, 1, 1, '100.000000');
            INSERT INTO usage_buckets VALUES (3, 1762560000, 'host:other', 'command:curl', 5, 2, 1, '200.000000');
            INSERT INTO daily_route_usage VALUES (3, '2026-11-08', 'host:legacy', 'command:curl', 'proxied', 10, 1, '100.000000');
            INSERT INTO process_names VALUES ('curl', 'host:legacy', '100.000000', 'command:curl');
            PRAGMA user_version = 12;
            """
        )

        _ = try UsageStore(databaseURL: url)

        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT download_bytes FROM daily_usage WHERE app_key = 'host:other' AND program_key = 'command:curl';"
            ),
            15
        )
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT sample_count FROM usage_buckets WHERE app_key = 'host:other' AND program_key = 'command:curl';"
            ),
            2
        )
        XCTAssertEqual(
            try database.scalarInt64("SELECT download_bytes FROM daily_usage WHERE app_key = 'host:system';"),
            7
        )
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT download_bytes FROM daily_route_usage WHERE app_key = 'host:other' AND route = 'proxied';"
            ),
            10
        )
        XCTAssertEqual(
            try database.scalarInt64("SELECT COUNT(*) FROM process_names WHERE process_name = 'curl' AND app_key = 'host:other';"),
            1
        )
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT COUNT(*) FROM apps WHERE app_key = 'host:other' AND display_name = '命令行工具' AND first_seen_at = '1750000000.000000';"
            ),
            1
        )
        XCTAssertEqual(
            try database.scalarInt64("SELECT COUNT(*) FROM apps WHERE app_key = 'host:system' AND category = 'system_process';"),
            1
        )
        XCTAssertEqual(
            try database.scalarInt64(
                "SELECT (SELECT COUNT(*) FROM apps WHERE app_key = 'host:legacy') + (SELECT COUNT(*) FROM daily_usage WHERE app_key = 'host:legacy');"
            ),
            0
        )
        XCTAssertEqual(try database.scalarInt64("SELECT SUM(download_bytes) FROM daily_usage;"), 22)
        XCTAssertEqual(try database.scalarInt64("PRAGMA user_version;"), UsageStore.schemaVersion)
    }

    func testProgramQueriesSplitHostsByProgram() throws {
        let url = temporaryDatabaseURL("program-queries")
        defer { removeDatabase(at: url) }

        let store = try UsageStore(databaseURL: url)
        let date = Date(timeIntervalSince1970: 1_762_560_000)
        let ghostty = (key: "bundle:com.mitchellh.ghostty", name: "Ghostty", bundleID: "com.mitchellh.ghostty")
        let curl = AttributedProgram(key: "command:curl", displayName: "curl", category: .unclassified, executablePath: "/usr/bin/curl")
        func aggregate(_ appKey: String, _ name: String, _ category: AppCategory, _ program: AttributedProgram?, _ bytes: Int64) -> DailyUsageAggregate {
            DailyUsageAggregate(
                day: "2026-11-08",
                appKey: appKey,
                displayName: name,
                category: category,
                bundleID: appKey == ghostty.key ? ghostty.bundleID : nil,
                bundlePath: nil,
                executablePath: nil,
                firstSeenAt: date,
                lastSeenAt: date,
                downloadBytes: bytes,
                uploadBytes: 0,
                sampleCount: 1,
                program: program
            )
        }
        try store.apply([
            aggregate(ghostty.key, ghostty.name, .userApp, nil, 10),
            aggregate(ghostty.key, ghostty.name, .userApp, curl, 20),
            aggregate(VirtualHost.otherKey, "命令行工具", .unclassified, curl, 40)
        ])

        let daily = try store.dailyUsage(for: "2026-11-08")
        XCTAssertEqual(daily.first { $0.appKey == ghostty.key }?.downloadBytes, 30)
        XCTAssertEqual(daily.first { $0.appKey == VirtualHost.otherKey }?.downloadBytes, 40)

        let programs = try store.programUsage(from: "2026-11-08", through: "2026-11-08")
        XCTAssertEqual(
            programs.filter { $0.programIdentity == "command:curl" }.reduce(0) { $0 + $1.downloadBytes },
            60
        )
        XCTAssertEqual(
            programs.first { $0.appKey == ghostty.key && $0.programKey.isEmpty }?.programIdentity,
            ghostty.key
        )
    }

    func testRememberedProcessNamesPreferRecordedMappings() throws {
        let url = temporaryDatabaseURL("process-names")
        defer { removeDatabase(at: url) }

        let store = try UsageStore(databaseURL: url)
        let database = try SQLiteDatabase(url: url)
        try database.execute(
            """
            INSERT INTO apps VALUES ('bundle:com.yetone.magpie', 'com.yetone.magpie', '/Applications/magpie.app', '/Applications/magpie.app/Contents/MacOS/magpie', 'magpie', 'user_app', '100.000000', '100.000000');
            INSERT INTO apps VALUES ('host:other', NULL, NULL, NULL, '命令行工具', 'unclassified', '100.000000', '100.000000');
            INSERT INTO programs VALUES ('command:mise', 'mise', 'unclassified', '/Users/u/.local/bin/mise', '100.000000', '200.000000');
            INSERT INTO programs VALUES ('command:VeryLongToolName', 'VeryLongToolName', 'unclassified', '/Users/u/.local/bin/VeryLongToolName', '100.000000', '200.000000');
            INSERT INTO daily_usage VALUES (3, '2026-11-08', 'host:other', 'command:VeryLongToolName', 1, 0, 1, '100.000000');
            """
        )
        try store.recordProcessNames([
            "mise": ProcessNameAttribution(appKey: "bundle:com.yetone.magpie", programKey: "command:mise")
        ])

        let remembered = Dictionary(
            try store.rememberedProcessAttributions().map { ($0.processName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertEqual(remembered["mise"]?.appKey, "bundle:com.yetone.magpie")
        XCTAssertEqual(remembered["mise"]?.category, .userApp)
        XCTAssertEqual(remembered["mise"]?.program?.key, "command:mise")
        XCTAssertEqual(remembered["magpie"]?.appKey, "bundle:com.yetone.magpie")
        XCTAssertNil(remembered["magpie"]?.program)
        // 没有已解析映射的程序按它最近出现的宿主预填。
        XCTAssertEqual(remembered["VeryLongToolNam"]?.appKey, VirtualHost.otherKey)
        XCTAssertEqual(remembered["VeryLongToolNam"]?.program?.key, "command:VeryLongToolName")
    }

    private func temporaryDatabaseURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-\(name)-\(UUID().uuidString).sqlite3")
    }

    private func removeDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
    }

    /// 版本 11 的表结构（没有 `program_key`，带 `app_launchers`）。
    private func createVersionElevenTables(in database: SQLiteDatabase) throws {
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
                accounting_version INTEGER NOT NULL,
                day TEXT NOT NULL,
                app_key TEXT NOT NULL,
                download_bytes INTEGER NOT NULL DEFAULT 0,
                upload_bytes INTEGER NOT NULL DEFAULT 0,
                sample_count INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (accounting_version, day, app_key)
            );
            CREATE TABLE usage_buckets (
                accounting_version INTEGER NOT NULL,
                bucket_start INTEGER NOT NULL,
                app_key TEXT NOT NULL,
                download_bytes INTEGER NOT NULL DEFAULT 0,
                upload_bytes INTEGER NOT NULL DEFAULT 0,
                sample_count INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (accounting_version, bucket_start, app_key)
            );
            CREATE INDEX idx_usage_buckets_start ON usage_buckets(accounting_version, bucket_start);
            CREATE TABLE daily_route_usage (
                accounting_version INTEGER NOT NULL,
                day TEXT NOT NULL,
                app_key TEXT NOT NULL,
                route TEXT NOT NULL,
                download_bytes INTEGER NOT NULL DEFAULT 0,
                upload_bytes INTEGER NOT NULL DEFAULT 0,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (accounting_version, day, app_key, route)
            );
            CREATE TABLE app_launchers (
                app_key TEXT PRIMARY KEY,
                launcher_name TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE process_names (
                process_name TEXT PRIMARY KEY,
                app_key TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE collector_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                occurred_at TEXT NOT NULL,
                kind TEXT NOT NULL,
                details TEXT
            );
            """
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
