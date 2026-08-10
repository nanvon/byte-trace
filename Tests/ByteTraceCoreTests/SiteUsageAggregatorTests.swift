import Foundation
import XCTest
@testable import ByteTraceCore

final class SiteUsageAggregatorTests: XCTestCase {
    func testSiteUsagePersistsSeparatelyForDailyAndMinuteRanges() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let calendar = Calendar(identifier: .gregorian)
        let aggregator = SiteUsageAggregator(store: store, calendar: calendar)
        let date = Date(timeIntervalSince1970: 1_700_000_010)

        try aggregator.ingest(delta(date: date, download: 7, upload: 3))
        try aggregator.ingest(delta(date: date.addingTimeInterval(5), download: 5, upload: 2))
        XCTAssertEqual(try aggregator.flush(), 1)

        let day = dayKey(date, calendar: calendar)
        let daily = try store.siteUsage(from: day, through: day)
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily[0].siteKey, "github.com")
        XCTAssertEqual(daily[0].downloadBytes, 12)
        XCTAssertEqual(daily[0].uploadBytes, 5)

        let minute = try store.siteUsage(
            from: date.addingTimeInterval(-60),
            to: date.addingTimeInterval(60)
        )
        XCTAssertEqual(minute, daily)
    }

    func testSiteMetadataDoesNotOverwriteNettopApplicationMetadata() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.apply(
            [
                DailyUsageAggregate(
                    day: "2023-11-14",
                    appKey: "bundle:example.browser",
                    displayName: "nettop 名称",
                    category: .userApp,
                    bundleID: "example.browser",
                    bundlePath: "/Applications/Browser.app",
                    executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                    firstSeenAt: date,
                    lastSeenAt: date,
                    downloadBytes: 1,
                    uploadBytes: 1,
                    sampleCount: 1
                )
            ]
        )

        let aggregator = SiteUsageAggregator(store: store)
        try aggregator.ingest(
            SiteUsageDelta(
                sampledAt: date,
                appKey: "bundle:example.browser",
                displayName: "Mihomo 名称",
                category: .unclassified,
                bundleID: nil,
                bundlePath: nil,
                executablePath: "/tmp/wrong",
                siteKey: "example.com",
                downloadBytes: 5,
                uploadBytes: 5
            )
        )
        try aggregator.flush()

        let app = try store.dailyUsage(for: "2023-11-14").first
        XCTAssertEqual(app?.displayName, "nettop 名称")
        XCTAssertEqual(app?.category, .userApp)
        XCTAssertEqual(app?.bundlePath, "/Applications/Browser.app")
    }

    func testRetentionPurgesBothMinuteTablesAndClearRemovesSiteDailyRows() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = SiteUsageAggregator(store: store)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try aggregator.ingest(delta(date: date, download: 1, upload: 1))
        try aggregator.flush()

        XCTAssertEqual(try store.purgeBuckets(before: date.addingTimeInterval(120)), 1)
        XCTAssertTrue(
            try store.siteUsage(from: date.addingTimeInterval(-60), to: date.addingTimeInterval(120)).isEmpty
        )
        XCTAssertFalse(
            try store.siteUsage(from: "2023-01-01", through: "2024-12-31").isEmpty
        )

        try store.clearAll()
        XCTAssertTrue(
            try store.siteUsage(from: "2023-01-01", through: "2024-12-31").isEmpty
        )
    }

    func testInvalidBytesAreRejectedAndZeroBytesAreIgnored() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = SiteUsageAggregator(store: store)
        XCTAssertThrowsError(
            try aggregator.ingest(delta(date: Date(), download: -1, upload: 0))
        )
        try aggregator.ingest(delta(date: Date(), download: 0, upload: 0))
        XCTAssertEqual(aggregator.pendingEntryCount, 0)
    }

    private func delta(date: Date, download: Int64, upload: Int64) -> SiteUsageDelta {
        SiteUsageDelta(
            sampledAt: date,
            appKey: "bundle:example.browser",
            displayName: "Browser",
            category: .userApp,
            bundleID: "example.browser",
            bundlePath: "/Applications/Browser.app",
            executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
            siteKey: "github.com",
            downloadBytes: download,
            uploadBytes: upload
        )
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
