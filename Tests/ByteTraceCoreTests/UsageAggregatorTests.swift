import XCTest

@testable import ByteTraceCore

final class UsageAggregatorTests: XCTestCase {
    func testSamplesMergeIntoDailyUsageAndPersist() throws {
        let calendar = utcCalendar()
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = UsageAggregator(store: store, calendar: calendar)
        let firstSample = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 10))!
        let secondSample = firstSample.addingTimeInterval(2)

        try aggregator.ingest(
            UsageDelta(
                sampledAt: firstSample,
                appKey: "bundle:com.example.app",
                displayName: "Example",
                category: .userApp,
                bundleID: "com.example.app",
                bundlePath: "/Applications/Example.app",
                executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                downloadBytes: 100,
                uploadBytes: 20
            )
        )
        try aggregator.ingest(
            UsageDelta(
                sampledAt: secondSample,
                appKey: "bundle:com.example.app",
                displayName: "Example Updated",
                category: .userApp,
                bundleID: "com.example.app",
                bundlePath: "/Applications/Example.app",
                executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                downloadBytes: 3,
                uploadBytes: 4
            )
        )

        XCTAssertEqual(aggregator.pendingEntryCount, 1)
        XCTAssertEqual(try aggregator.flush(), 1)
        XCTAssertEqual(aggregator.pendingEntryCount, 0)

        let records = try store.dailyUsage(for: "2026-08-01")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].downloadBytes, 103)
        XCTAssertEqual(records[0].uploadBytes, 24)
        XCTAssertEqual(records[0].sampleCount, 2)
        XCTAssertEqual(records[0].displayName, "Example Updated")

        let buckets = try store.bucketUsage(
            from: firstSample,
            to: firstSample.addingTimeInterval(60)
        )
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].downloadBytes, 103)
        XCTAssertEqual(buckets[0].uploadBytes, 24)
        XCTAssertEqual(buckets[0].sampleCount, 2)

        let stats = try store.bucketStats()
        XCTAssertEqual(stats.bucketCount, 1)
        XCTAssertEqual(stats.earliestBucket, firstSample)
        XCTAssertEqual(stats.latestBucket, firstSample)
    }

    func testSamplesInDifferentMinutesPersistSeparateBuckets() throws {
        let calendar = utcCalendar()
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = UsageAggregator(store: store, calendar: calendar)
        let firstSample = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 1, hour: 10, minute: 0, second: 1)
        )!
        let secondSample = firstSample.addingTimeInterval(61)

        try aggregator.ingest(makeDelta(at: firstSample, download: 100, upload: 10))
        try aggregator.ingest(makeDelta(at: secondSample, download: 30, upload: 3))
        try aggregator.flush()

        let bucketStart = calendar.dateInterval(of: .minute, for: firstSample)!.start
        let buckets = try store.bucketUsage(
            from: bucketStart,
            to: secondSample.addingTimeInterval(60)
        )
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.map(\.downloadBytes), [100, 30])

        let dailyRecords = try store.dailyUsage(for: "2026-08-01")
        XCTAssertEqual(dailyRecords.count, 1)
        XCTAssertEqual(dailyRecords[0].downloadBytes, 130)
        XCTAssertEqual(dailyRecords[0].uploadBytes, 13)
        XCTAssertEqual(dailyRecords[0].sampleCount, 2)

        let secondBucketStart = calendar.dateInterval(of: .minute, for: secondSample)!.start
        XCTAssertEqual(try store.purgeBuckets(before: secondBucketStart), 1)
        XCTAssertEqual(try store.bucketStats().bucketCount, 1)
        XCTAssertEqual(
            try store.bucketUsage(
                from: secondBucketStart,
                to: secondBucketStart.addingTimeInterval(60)
            ).map(\.downloadBytes),
            [30]
        )

        let dailyAfterPurge = try store.dailyUsage(for: "2026-08-01")
        XCTAssertEqual(dailyAfterPurge[0].downloadBytes, 130)
        XCTAssertEqual(dailyAfterPurge[0].uploadBytes, 13)
        XCTAssertEqual(dailyAfterPurge[0].sampleCount, 2)
    }

    func testBatchedApplyKeepsLatestAppMetadataAcrossBuckets() throws {
        let calendar = utcCalendar()
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = UsageAggregator(store: store, calendar: calendar)
        let firstSample = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 1, hour: 10, minute: 0, second: 1)
        )!
        let secondSample = firstSample.addingTimeInterval(61)

        try aggregator.ingest(
            makeDelta(
                at: firstSample,
                displayName: "Example Old",
                download: 100,
                upload: 10
            )
        )
        try aggregator.ingest(
            makeDelta(
                at: secondSample,
                displayName: "Example Current",
                download: 30,
                upload: 3
            )
        )
        try aggregator.flush()

        let daily = try XCTUnwrap(try store.dailyUsage(for: "2026-08-01").first)
        XCTAssertEqual(daily.displayName, "Example Current")
        XCTAssertEqual(daily.downloadBytes, 130)
        XCTAssertEqual(daily.uploadBytes, 13)

        let buckets = try store.bucketUsage(
            from: firstSample.addingTimeInterval(-1),
            to: secondSample.addingTimeInterval(60)
        )
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(Set(buckets.map(\.displayName)), ["Example Current"])
        XCTAssertEqual(buckets.map(\.downloadBytes), [100, 30])
    }

    func testBucketSummaryAndTimelineMatchDetailedRows() throws {
        let calendar = utcCalendar()
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = UsageAggregator(store: store, calendar: calendar)
        let firstMinute = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 1, hour: 10)
        )!
        let secondMinute = firstMinute.addingTimeInterval(60)
        let end = secondMinute.addingTimeInterval(60)

        try aggregator.ingest(makeDelta(at: firstMinute, download: 100, upload: 10))
        try aggregator.ingest(makeDelta(at: secondMinute, download: 30, upload: 3))
        try aggregator.ingest(
            makeDelta(
                at: firstMinute,
                appKey: "bundle:com.example.second",
                displayName: "Second",
                download: 7,
                upload: 4
            )
        )
        try aggregator.ingest(
            makeDelta(
                at: firstMinute,
                appKey: "proxy:test",
                displayName: "Proxy",
                category: .proxyTransport,
                download: 1_000,
                upload: 2_000
            )
        )
        try aggregator.flush()

        let detailed = try store.bucketUsage(from: firstMinute, to: end)
        let summaries = try store.bucketUsageSummary(from: firstMinute, to: end)
        XCTAssertEqual(summaries.count, 3)
        for summary in summaries {
            let rows = detailed.filter { $0.appKey == summary.appKey }
            XCTAssertEqual(summary.firstBucketStart, rows.map(\.bucketStart).min())
            XCTAssertEqual(summary.downloadBytes, rows.reduce(0) { $0 + $1.downloadBytes })
            XCTAssertEqual(summary.uploadBytes, rows.reduce(0) { $0 + $1.uploadBytes })
            XCTAssertEqual(summary.sampleCount, rows.reduce(0) { $0 + $1.sampleCount })
        }

        XCTAssertEqual(
            try store.bucketTimeline(from: firstMinute, to: end),
            [
                UsageTimelineRecord(
                    bucketStart: firstMinute,
                    downloadBytes: 107,
                    uploadBytes: 14
                ),
                UsageTimelineRecord(
                    bucketStart: secondMinute,
                    downloadBytes: 30,
                    uploadBytes: 3
                )
            ]
        )
        XCTAssertEqual(
            try store.bucketTimeline(
                from: firstMinute,
                to: end,
                appKey: "bundle:com.example.app",
                excludingProxyTransport: false
            ),
            [
                UsageTimelineRecord(
                    bucketStart: firstMinute,
                    downloadBytes: 100,
                    uploadBytes: 10
                ),
                UsageTimelineRecord(
                    bucketStart: secondMinute,
                    downloadBytes: 30,
                    uploadBytes: 3
                )
            ]
        )
    }

    func testBucketAggregatesPreserveSaturatingOverflowSemantics() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let firstMinute = Date(timeIntervalSince1970: 1_786_000_000)
        let secondMinute = firstMinute.addingTimeInterval(60)
        let end = secondMinute.addingTimeInterval(60)

        try store.apply(
            [],
            bucketAggregates: [
                makeBucketAggregate(
                    at: firstMinute,
                    appKey: "bundle:com.example.first",
                    download: Int64.max
                ),
                makeBucketAggregate(
                    at: secondMinute,
                    appKey: "bundle:com.example.first",
                    download: 1
                ),
                makeBucketAggregate(
                    at: firstMinute,
                    appKey: "bundle:com.example.second",
                    download: Int64.max
                )
            ]
        )

        let summaries = try store.bucketUsageSummary(from: firstMinute, to: end)
        let firstSummary = try XCTUnwrap(
            summaries.first { $0.appKey == "bundle:com.example.first" }
        )
        XCTAssertEqual(firstSummary.downloadBytes, Int64.max)
        XCTAssertEqual(firstSummary.sampleCount, 2)

        XCTAssertEqual(
            try store.bucketTimeline(from: firstMinute, to: end),
            [
                UsageTimelineRecord(
                    bucketStart: firstMinute,
                    downloadBytes: Int64.max,
                    uploadBytes: 0
                ),
                UsageTimelineRecord(
                    bucketStart: secondMinute,
                    downloadBytes: 1,
                    uploadBytes: 0
                )
            ]
        )
    }

    func testSamplesAcrossMidnightUseDifferentLocalDays() throws {
        let calendar = utcCalendar()
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = UsageAggregator(store: store, calendar: calendar)
        let beforeMidnight = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 1, hour: 23, minute: 59, second: 59)
        )!
        let afterMidnight = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 2, hour: 0, minute: 0, second: 1)
        )!

        try aggregator.ingest(makeDelta(at: beforeMidnight, download: 10, upload: 1))
        try aggregator.ingest(makeDelta(at: afterMidnight, download: 20, upload: 2))
        try aggregator.flush()

        XCTAssertEqual(try store.dailyUsage(for: "2026-08-01")[0].downloadBytes, 10)
        XCTAssertEqual(try store.dailyUsage(for: "2026-08-02")[0].downloadBytes, 20)
    }

    func testZeroSamplesAreIgnoredAndNegativeSamplesAreRejected() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = UsageAggregator(store: store, calendar: utcCalendar())
        let date = Date(timeIntervalSince1970: 100)

        try aggregator.ingest(makeDelta(at: date, download: 0, upload: 0))
        XCTAssertEqual(aggregator.pendingEntryCount, 0)

        XCTAssertThrowsError(try aggregator.ingest(makeDelta(at: date, download: -1, upload: 0))) { error in
            XCTAssertEqual(error as? UsageAggregatorError, .invalidBytes)
        }
    }

    func testPendingQueueLimitAndInt64OverflowAreEnforced() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let date = Date(timeIntervalSince1970: 100)
        let limited = UsageAggregator(store: store, calendar: utcCalendar(), maxPendingEntries: 1)

        try limited.ingest(makeDelta(at: date, appKey: "process:first", download: 1, upload: 0))
        XCTAssertThrowsError(
            try limited.ingest(makeDelta(at: date, appKey: "process:second", download: 1, upload: 0))
        ) { error in
            XCTAssertEqual(error as? UsageAggregatorError, .pendingLimitExceeded)
        }

        let overflow = UsageAggregator(store: store, calendar: utcCalendar())
        try overflow.ingest(makeDelta(at: date, appKey: "process:overflow", download: Int64.max, upload: 0))
        XCTAssertThrowsError(
            try overflow.ingest(makeDelta(at: date, appKey: "process:overflow", download: 1, upload: 0))
        ) { error in
            XCTAssertEqual(error as? UsageAggregatorError, .overflow)
        }
    }

    private func makeDelta(
        at date: Date,
        appKey: String = "bundle:com.example.app",
        displayName: String = "Example",
        category: AppCategory = .userApp,
        download: Int64,
        upload: Int64
    ) -> UsageDelta {
        UsageDelta(
            sampledAt: date,
            appKey: appKey,
            displayName: displayName,
            category: category,
            bundleID: "com.example.app",
            bundlePath: "/Applications/Example.app",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            downloadBytes: download,
            uploadBytes: upload
        )
    }

    private func makeBucketAggregate(
        at date: Date,
        appKey: String,
        download: Int64
    ) -> UsageBucketAggregate {
        UsageBucketAggregate(
            bucketStart: date,
            appKey: appKey,
            displayName: appKey,
            category: .userApp,
            bundleID: nil,
            bundlePath: nil,
            executablePath: nil,
            firstSeenAt: date,
            lastSeenAt: date,
            downloadBytes: download,
            uploadBytes: 0,
            sampleCount: 1
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
