import Foundation
import XCTest

@testable import ByteTraceCore

final class DomainUsageTests: XCTestCase {
    func testRecordsAcrossDaysAndClearsWithUsage() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let aggregator = UsageAggregator(store: store, calendar: calendar)
        let first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12)))
        let second = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: first))

        for date in [first, first, second] {
            try aggregator.ingest(sample(at: date, domain: "example.com"))
            try aggregator.flush()
        }
        try aggregator.ingest(sample(at: second, domain: nil))
        try aggregator.ingest(sample(at: second, domain: "example.com", route: .proxyRuleDirect))
        try aggregator.ingest(sample(at: second, domain: "example.com", route: nil))
        try aggregator.ingest(sample(at: second, domain: "example.com", route: .direct))
        try aggregator.ingest(sample(at: second, domain: "example.com", category: .proxyTransport))
        try aggregator.ingest(sample(at: second, domain: "", route: .proxyNode))
        try aggregator.flush()

        let appKey = "bundle:example"
        let range = try store.domainUsage(appKey: appKey, from: "2026-11-12", through: "2026-11-13")
        XCTAssertEqual(range.count, 2)
        XCTAssertEqual(range.first { $0.route == .proxyNode }?.downloadBytes, 30)
        XCTAssertEqual(range.first { $0.route == .proxyRuleDirect }?.uploadBytes, 2)
        XCTAssertEqual(try store.domainUsage(from: "2026-11-12", through: "2026-11-12").first?.downloadBytes, 20)
        XCTAssertEqual(try store.domainUsage(from: "2026-11-13", through: "2026-11-13").count, 2)
        XCTAssertTrue(try store.domainUsage(appKey: "bundle:missing", from: "2026-11-12", through: "2026-11-13").isEmpty)
        let daily = try store.dailyUsage(from: "2026-11-12", through: "2026-11-13").filter { $0.appKey == appKey }
        XCTAssertEqual(daily.reduce(0) { $0 + $1.downloadBytes }, 80)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.uploadBytes }, 16)
        XCTAssertLessThanOrEqual(range.reduce(0) { $0 + $1.downloadBytes }, daily.reduce(0) { $0 + $1.downloadBytes })

        try store.clearAll()
        XCTAssertTrue(try store.domainUsage(from: "2026-11-12", through: "2026-11-13").isEmpty)
        XCTAssertTrue(try store.dailyUsage(from: "2026-11-12", through: "2026-11-13").isEmpty)
    }

    func testDomainCapacityAndDiscardPreserveOverallAccounting() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = UsageAggregator(store: store, maxPendingEntries: 1)
        let date = Date()
        try aggregator.ingest(sample(at: date, domain: "discarded.example"))
        aggregator.discardPending()
        for domain in ["example.com", "example.net", "example.com"] {
            try aggregator.ingest(sample(at: date, domain: domain))
        }
        try aggregator.flush()
        XCTAssertEqual(try aggregator.flush(), 0)
        let records = try store.domainUsage(from: "0001-01-01", through: "9999-12-31")
        XCTAssertEqual(records.map(\.domain), ["example.com"])
        XCTAssertEqual(records.first?.downloadBytes, 20)
        let daily = try store.dailyUsage(from: "0001-01-01", through: "9999-12-31")
        XCTAssertEqual(daily.first?.downloadBytes, 30)
        XCTAssertEqual(daily.first?.uploadBytes, 6)
    }

    private func sample(
        at date: Date, domain: String?, route: TrafficRoute? = .proxyNode, category: AppCategory = .userApp
    ) -> UsageDelta {
        UsageDelta(
            sampledAt: date,
            appKey: category == .proxyTransport ? "proxy:example" : "bundle:example",
            displayName: "示例", category: category, downloadBytes: 10, uploadBytes: 2,
            route: route, domain: domain
        )
    }
}
