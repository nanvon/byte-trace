import Foundation
import XCTest

@testable import ByteTraceCore

final class RouteUsageTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func delta(
        at date: Date,
        appKey: String = "bundle:com.example.app",
        category: AppCategory = .userApp,
        download: Int64,
        upload: Int64,
        route: TrafficRoute?
    ) -> UsageDelta {
        UsageDelta(
            sampledAt: date,
            appKey: appKey,
            displayName: "Example",
            category: category,
            downloadBytes: download,
            uploadBytes: upload,
            route: route
        )
    }

    func testRoutesAccumulatePerDayWithoutChangingTotals() throws {
        let calendar = utcCalendar()
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        let aggregator = UsageAggregator(store: store, calendar: calendar)
        let sample = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 10))!

        try aggregator.ingest(delta(at: sample, download: 100, upload: 10, route: .direct))
        try aggregator.ingest(delta(at: sample.addingTimeInterval(1), download: 50, upload: 5, route: .proxied))
        try aggregator.ingest(delta(at: sample.addingTimeInterval(2), download: 7, upload: 3, route: .proxied))
        try aggregator.ingest(
            delta(at: sample, appKey: "proxy:mihomo", category: .proxyTransport, download: 900, upload: 90, route: nil)
        )
        try aggregator.flush()
        try aggregator.ingest(delta(at: sample.addingTimeInterval(3), download: 1, upload: 1, route: .direct))
        try aggregator.flush()

        let daily = try store.dailyUsage(for: "2026-08-01")
        let app = try XCTUnwrap(daily.first { $0.appKey == "bundle:com.example.app" })
        XCTAssertEqual(app.downloadBytes, 158)
        XCTAssertEqual(app.uploadBytes, 19)

        let routes = try store.routeUsage(from: "2026-08-01", through: "2026-08-01")
        XCTAssertEqual(routes.count, 2)
        let direct = try XCTUnwrap(routes.first { $0.route == .direct })
        let proxied = try XCTUnwrap(routes.first { $0.route == .proxied })
        XCTAssertEqual(direct.downloadBytes, 101)
        XCTAssertEqual(direct.uploadBytes, 11)
        XCTAssertEqual(proxied.totalBytes, 65)
        XCTAssertFalse(routes.contains { $0.appKey == "proxy:mihomo" })
    }

    func testReducerSplitsConnectionsByRoute() {
        let endpoint = NettopEndpoint(host: "127.0.0.1", port: 7890)
        func connection(_ localPort: Int, download: Int64) -> NettopDelta {
            NettopDelta(
                sampledAt: "10:00:00.000",
                processName: "Dia.1",
                downloadBytes: download,
                uploadBytes: 0,
                interface: "lo0",
                connectionTarget: "127.0.0.1:7890",
                localEndpoint: NettopEndpoint(host: "127.0.0.1", port: UInt16(localPort)),
                remoteEndpoint: endpoint
            )
        }

        let reduced = SupplementalTrafficReducer().reduceWithRoutes(
            [connection(50001, download: 10), connection(50002, download: 20), connection(50003, download: 5)],
            proxyEndpoints: [endpoint],
            route: { $0.localEndpoint?.port == 50002 ? .proxyRuleDirect : .proxyNode }
        )

        XCTAssertEqual(reduced.count, 2)
        XCTAssertEqual(reduced.first { $0.route == .proxyNode }?.delta.downloadBytes, 15)
        XCTAssertEqual(reduced.first { $0.route == .proxyRuleDirect }?.delta.downloadBytes, 20)
    }
}
