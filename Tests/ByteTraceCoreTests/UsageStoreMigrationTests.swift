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

        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("PRAGMA user_version = 3;")
        }

        let store = try UsageStore(databaseURL: url)
        let dailyRecords = try store.dailyUsage(for: "2025-07-18")
        let bucketRecords = try store.bucketUsage(
            from: sampleDate.addingTimeInterval(-60),
            to: sampleDate.addingTimeInterval(60)
        )

        XCTAssertEqual(dailyRecords.count, 1)
        XCTAssertEqual(dailyRecords[0].appKey, "bundle:com.nanvon.ccbar")
        XCTAssertEqual(dailyRecords[0].category, .userApp)
        XCTAssertEqual(dailyRecords[0].downloadBytes, 10)
        XCTAssertEqual(dailyRecords[0].uploadBytes, 4)

        XCTAssertEqual(bucketRecords.count, 1)
        XCTAssertEqual(bucketRecords[0].appKey, "bundle:com.nanvon.ccbar")
        XCTAssertEqual(bucketRecords[0].category, .userApp)
    }

    private func seedLegacyCCBarUsage(at url: URL, sampleDate: Date) throws {
        let store = try UsageStore(databaseURL: url)
        try store.apply(
            [
                DailyUsageAggregate(
                    day: "2025-07-18",
                    appKey: "proxy:ccbar",
                    displayName: "CCBar",
                    category: .proxyTransport,
                    bundleID: "com.nanvon.ccbar",
                    bundlePath: "/Applications/CCBar.app",
                    executablePath: "/Applications/CCBar.app/Contents/MacOS/CCBar",
                    firstSeenAt: sampleDate,
                    lastSeenAt: sampleDate,
                    downloadBytes: 10,
                    uploadBytes: 4,
                    sampleCount: 1
                )
            ],
            bucketAggregates: [
                UsageBucketAggregate(
                    bucketStart: sampleDate,
                    appKey: "proxy:ccbar",
                    displayName: "CCBar",
                    category: .proxyTransport,
                    bundleID: "com.nanvon.ccbar",
                    bundlePath: "/Applications/CCBar.app",
                    executablePath: "/Applications/CCBar.app/Contents/MacOS/CCBar",
                    firstSeenAt: sampleDate,
                    lastSeenAt: sampleDate,
                    downloadBytes: 10,
                    uploadBytes: 4,
                    sampleCount: 1
                )
            ]
        )
    }
}
