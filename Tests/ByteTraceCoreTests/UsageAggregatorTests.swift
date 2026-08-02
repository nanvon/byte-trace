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
        download: Int64,
        upload: Int64
    ) -> UsageDelta {
        UsageDelta(
            sampledAt: date,
            appKey: appKey,
            displayName: "Example",
            category: .userApp,
            bundleID: "com.example.app",
            bundlePath: "/Applications/Example.app",
            executablePath: "/Applications/Example.app/Contents/MacOS/Example",
            downloadBytes: download,
            uploadBytes: upload
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
