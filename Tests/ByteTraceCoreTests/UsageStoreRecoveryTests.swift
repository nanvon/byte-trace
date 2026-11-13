import Foundation
import XCTest

@testable import ByteTraceCore

final class UsageStoreRecoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRandomBytesAreReportedAsCorruption() throws {
        let url = directory.appendingPathComponent("usage.sqlite3")
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<4096).map { _ in UInt8.random(in: 0...255, using: &generator) }
        try Data(bytes).write(to: url)

        XCTAssertThrowsError(try UsageStore(databaseURL: url)) { error in
            XCTAssertTrue(UsageStore.isCorruption(error), "\(error)")
            XCTAssertFalse(UsageStore.isNewerSchema(error))
        }
    }

    func testNewerSchemaIsNotCorruption() throws {
        let url = directory.appendingPathComponent("usage.sqlite3")
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("PRAGMA user_version = 9999;")
        }

        XCTAssertThrowsError(try UsageStore(databaseURL: url)) { error in
            XCTAssertTrue(UsageStore.isNewerSchema(error), "\(error)")
            XCTAssertFalse(UsageStore.isCorruption(error))
        }
    }

    func testPathThatIsADirectoryIsNeitherCorruptionNorNewerSchema() throws {
        let url = directory.appendingPathComponent("usage.sqlite3", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertThrowsError(try UsageStore(databaseURL: url)) { error in
            XCTAssertFalse(UsageStore.isCorruption(error), "\(error)")
            XCTAssertFalse(UsageStore.isNewerSchema(error))
        }
    }

    func testQuarantineMovesDatabaseAndSidecarsThenAllowsFreshStore() throws {
        let url = directory.appendingPathComponent("usage.sqlite3")
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
        }
        let now = Date(timeIntervalSince1970: 1_763_000_000)

        let target = try UsageStore.quarantineDatabase(at: url, now: now)

        XCTAssertTrue(target.lastPathComponent.hasPrefix("usage.corrupt-"))
        XCTAssertEqual(target.pathExtension, "sqlite3")
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path + suffix))
        }
        let store = try UsageStore(databaseURL: url)
        XCTAssertEqual(try store.bucketStats().bucketCount, 0)
    }

    func testQuarantineTwiceInTheSameSecondKeepsBothFiles() throws {
        let url = directory.appendingPathComponent("usage.sqlite3")
        let now = Date(timeIntervalSince1970: 1_763_000_000)

        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("first".utf8)))
        let first = try UsageStore.quarantineDatabase(at: url, now: now)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data("second".utf8)))
        let second = try UsageStore.quarantineDatabase(at: url, now: now)

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.deletingPathExtension().lastPathComponent.hasSuffix("-2"))
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    func testQuarantineRestoresDatabaseWhenSidecarMoveFails() throws {
        // APFS 单个文件名最多 255 字节。隔离后的主文件名是 253 字节，
        // 追加 -wal 后超限，让旁文件移动在主文件移动成功后失败。
        let name = String(repeating: "x", count: 221) + ".sqlite3"
        let url = directory.appendingPathComponent(name)
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let original = Data("database".utf8)
        let journal = Data("journal".utf8)
        try original.write(to: url)
        try journal.write(to: wal)

        XCTAssertThrowsError(try UsageStore.quarantineDatabase(at: url))

        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try Data(contentsOf: wal), journal)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            Set([url.lastPathComponent, wal.lastPathComponent])
        )
    }

    func testClearAllRollsBackEarlierDeletesOnFailure() throws {
        let url = directory.appendingPathComponent("usage.sqlite3")
        let store = try UsageStore(databaseURL: url)
        let aggregator = UsageAggregator(store: store)
        try aggregator.ingest(UsageDelta(
            sampledAt: Date(), appKey: "bundle:example", displayName: "示例",
            category: .userApp, downloadBytes: 10, uploadBytes: 2,
            route: .proxyNode, domain: "example.com"
        ))
        try aggregator.flush()
        try store.recordCollectorEvent(kind: "example")
        let fault = try SQLiteDatabase(url: url)
        try fault.execute("""
            CREATE TRIGGER fail_clear BEFORE DELETE ON collector_events
            BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END;
            """)

        XCTAssertThrowsError(try store.clearAll())

        XCTAssertEqual(try store.bucketStats().bucketCount, 1)
        XCTAssertEqual(try store.dailyUsage(from: "0001-01-01", through: "9999-12-31").first?.downloadBytes, 10)
        XCTAssertEqual(try store.routeUsage(from: "0001-01-01", through: "9999-12-31").first?.downloadBytes, 10)
        XCTAssertEqual(try store.domainUsage(from: "0001-01-01", through: "9999-12-31").first?.downloadBytes, 10)
        XCTAssertEqual(try fault.scalarInt64("SELECT COUNT(*) FROM collector_events;"), 1)
    }

    func testFailedUsageWriteCanBeRetriedWithoutCountingTwice() throws {
        let url = directory.appendingPathComponent("usage.sqlite3")
        let store = try UsageStore(databaseURL: url)
        let aggregator = UsageAggregator(store: store)
        try aggregator.ingest(UsageDelta(
            sampledAt: Date(), appKey: "bundle:example", displayName: "示例",
            category: .userApp, downloadBytes: 10, uploadBytes: 2,
            route: .proxyNode, domain: "example.com"
        ))
        let fault = try SQLiteDatabase(url: url)
        try fault.execute("""
            CREATE TRIGGER fail_usage_write BEFORE INSERT ON daily_domain_usage
            BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;
            """)

        XCTAssertThrowsError(try aggregator.flush())
        XCTAssertEqual(aggregator.pendingEntryCount, 1)
        XCTAssertTrue(try store.dailyUsage(from: "0001-01-01", through: "9999-12-31").isEmpty)

        try fault.execute("DROP TRIGGER fail_usage_write;")
        XCTAssertEqual(try aggregator.flush(), 1)
        XCTAssertEqual(try aggregator.flush(), 0)
        XCTAssertEqual(try store.dailyUsage(from: "0001-01-01", through: "9999-12-31").first?.downloadBytes, 10)
    }
}
