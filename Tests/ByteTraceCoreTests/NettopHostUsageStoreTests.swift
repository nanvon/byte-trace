import XCTest

@testable import ByteTraceCore

final class NettopHostUsageStoreTests: XCTestCase {
    func testHostUsagePersistsAndQueriesWithHalfOpenBucketRange() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let firstBucket = Date(timeIntervalSince1970: 60)
        let secondSample = firstBucket.addingTimeInterval(5)

        try store.applyHostUsage([
            makeRecord(
                bucketStart: firstBucket,
                firstSampleAt: firstBucket,
                lastSampleAt: firstBucket,
                connectionCount: 1,
                downloadBytes: 100,
                uploadBytes: 20,
                displayName: "Example"
            )
        ])
        try store.applyHostUsage([
            makeRecord(
                bucketStart: firstBucket,
                firstSampleAt: firstBucket,
                lastSampleAt: secondSample,
                connectionCount: 1,
                downloadBytes: 3,
                uploadBytes: 4,
                displayName: "Example Updated"
            )
        ])

        let records = try store.hostUsage(
            from: firstBucket,
            to: firstBucket.addingTimeInterval(60),
            appKey: "bundle:com.example.app"
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].bucketStart, firstBucket)
        XCTAssertEqual(records[0].hostname, "example.com")
        XCTAssertEqual(records[0].downloadBytes, 103)
        XCTAssertEqual(records[0].uploadBytes, 24)
        XCTAssertEqual(records[0].connectionCount, 2)
        XCTAssertEqual(records[0].displayName, "Example Updated")
        XCTAssertEqual(records[0].firstSampleAt, firstBucket)
        XCTAssertEqual(records[0].lastSampleAt, secondSample)

        XCTAssertTrue(
            try store.hostUsage(
                from: firstBucket.addingTimeInterval(60),
                to: firstBucket.addingTimeInterval(120)
            ).isEmpty
        )
    }

    func testUnattributedEndpointRoundTripsAndIndependentClearPreservesAppUsage() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let date = Date(timeIntervalSince1970: 100)

        try store.apply([
            DailyUsageAggregate(
                day: "2026-08-02",
                appKey: "bundle:com.example.app",
                displayName: "Example",
                category: .userApp,
                bundleID: "com.example.app",
                bundlePath: "/Applications/Example.app",
                executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                firstSeenAt: date,
                lastSeenAt: date,
                downloadBytes: 50,
                uploadBytes: 5,
                sampleCount: 1
            )
        ])
        try store.applyHostUsage([
            NettopHostUsageRecord(
                bucketStart: date,
                appKey: nil,
                displayName: nil,
                endpointKind: .unknown,
                hostname: nil,
                firstSampleAt: date,
                lastSampleAt: date,
                connectionCount: 1,
                downloadBytes: 7,
                uploadBytes: 2
            )
        ])

        let record = try XCTUnwrap(
            try store.hostUsage(from: date, to: date.addingTimeInterval(60)).first
        )
        XCTAssertNil(record.appKey)
        XCTAssertNil(record.hostname)
        XCTAssertEqual(record.endpointKind, .unknown)

        try store.clearHostUsage()

        XCTAssertTrue(try store.hostUsage(from: date, to: date.addingTimeInterval(60)).isEmpty)
        XCTAssertEqual(try store.dailyUsage(for: "2026-08-02")[0].downloadBytes, 50)
    }

    private func makeRecord(
        bucketStart: Date,
        firstSampleAt: Date,
        lastSampleAt: Date,
        connectionCount: Int64,
        downloadBytes: Int64,
        uploadBytes: Int64,
        displayName: String
    ) -> NettopHostUsageRecord {
        NettopHostUsageRecord(
            bucketStart: bucketStart,
            appKey: "bundle:com.example.app",
            displayName: displayName,
            endpointKind: .hostname,
            hostname: "example.com",
            firstSampleAt: firstSampleAt,
            lastSampleAt: lastSampleAt,
            connectionCount: connectionCount,
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes
        )
    }
}
