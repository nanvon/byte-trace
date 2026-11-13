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
}
