import XCTest

@testable import ByteTraceCore

final class SupplementalResidualTrackerTests: XCTestCase {
    private let proxy = NettopEndpoint(host: "127.0.0.1", port: 7890)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func connection(_ process: String, _ description: String, _ interface: String, _ download: Int64) -> NettopDelta {
        let parts = description.components(separatedBy: "<->")
        return NettopDelta(
            sampledAt: "20:00:00.000",
            processName: process,
            downloadBytes: download,
            uploadBytes: 0,
            interface: interface,
            connectionTarget: parts[1],
            localEndpoint: NettopEndpoint.parse(parts[0]),
            remoteEndpoint: NettopEndpoint.parse(parts[1])
        )
    }

    private func total(_ process: String, _ download: Int64) -> NettopDelta {
        NettopDelta(sampledAt: "20:00:01.000", processName: process, downloadBytes: download, uploadBytes: 0)
    }

    func testClosedProxyConnectionBytesAreRecoveredFromProcessRow() {
        var tracker = SupplementalResidualTracker()
        let first = tracker.residuals(
            processTotals: [total("curl.1", 3_900_000)],
            connections: [connection("curl.1", "127.0.0.1:49502<->127.0.0.1:7890", "lo0", 3_900_000)],
            proxyEndpoints: [proxy],
            at: start
        )
        XCTAssertEqual(first, [])

        // 连接关闭后连接行消失，剩余字节只在进程行里。
        let second = tracker.residuals(
            processTotals: [total("curl.1", 6_100_000)],
            connections: [],
            proxyEndpoints: [proxy],
            at: start.addingTimeInterval(1),
            route: { _ in .proxyNode }
        )
        XCTAssertEqual(second.map(\.delta.downloadBytes), [6_100_000])
        XCTAssertEqual(second.map(\.delta.interface), ["lo0"])
        XCTAssertEqual(second.map(\.route), [.proxied])
    }

    func testSkipsProcessesWithDiscardedLocalTrafficOrNoHistory() {
        var tracker = SupplementalResidualTracker()
        _ = tracker.residuals(
            processTotals: [total("Code.2", 300)],
            connections: [
                connection("Code.2", "127.0.0.1:50000<->127.0.0.1:7890", "lo0", 100),
                connection("Code.2", "127.0.0.1:50001<->127.0.0.1:3000", "lo0", 200)
            ],
            proxyEndpoints: [proxy],
            at: start
        )
        let residuals = tracker.residuals(
            processTotals: [total("Code.2", 500), total("Unknown.3", 800)],
            connections: [],
            proxyEndpoints: [proxy],
            at: start.addingTimeInterval(1)
        )
        XCTAssertEqual(residuals, [])
    }

    func testUsesDominantRecentKindAndExpiresHistory() {
        var tracker = SupplementalResidualTracker()
        _ = tracker.residuals(
            processTotals: [],
            connections: [
                connection("Dia.4", "198.18.0.1:60000<->1.1.1.1:443", "utun4", 1_000),
                connection("Dia.4", "127.0.0.1:50002<->127.0.0.1:7890", "lo0", 10)
            ],
            proxyEndpoints: [proxy],
            at: start
        )
        let residuals = tracker.residuals(
            processTotals: [total("Dia.4", 50)],
            connections: [],
            proxyEndpoints: [proxy],
            at: start.addingTimeInterval(2)
        )
        XCTAssertEqual(residuals.map(\.delta.interface), ["utun"])

        let expired = tracker.residuals(
            processTotals: [total("Dia.4", 50)],
            connections: [],
            proxyEndpoints: [proxy],
            at: start.addingTimeInterval(SupplementalResidualTracker.historyWindow + 1)
        )
        XCTAssertEqual(expired, [])
    }
}
