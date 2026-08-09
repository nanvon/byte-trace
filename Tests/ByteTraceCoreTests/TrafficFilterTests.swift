import XCTest

@testable import ByteTraceCore

final class TrafficFilterTests: XCTestCase {
    private func delta(
        _ process: String = "Dia.1",
        target: String?,
        interface: String? = "utun4"
    ) -> NettopDelta {
        NettopDelta(
            sampledAt: "20:00:00.000",
            processName: process,
            downloadBytes: 100,
            uploadBytes: 200,
            interface: interface,
            connectionTarget: target
        )
    }

    func testLoopbackIPv4TargetIsDiscarded() {
        let filter = TrafficFilter()
        XCTAssertTrue(filter.shouldDiscard(delta(target: "127.0.0.1:59169", interface: "lo0")))
        XCTAssertTrue(filter.shouldDiscard(delta(target: "127.0.0.1:7890", interface: "lo0")))
    }

    func testLoopbackIPv6TargetIsDiscarded() {
        let filter = TrafficFilter()
        XCTAssertTrue(filter.shouldDiscard(delta(target: "[::1]:443", interface: "lo0")))
        XCTAssertTrue(filter.shouldDiscard(delta(target: "::1.8021", interface: "lo0")))
    }

    func testPublicAndLANTargetsAreKept() {
        let filter = TrafficFilter()
        XCTAssertFalse(filter.shouldDiscard(delta(target: "91.108.56.139:443")))
        XCTAssertFalse(filter.shouldDiscard(delta(target: "54.199.45.99:443")))
        XCTAssertFalse(filter.shouldDiscard(delta(target: "192.168.31.5:5000")))
        XCTAssertFalse(filter.shouldDiscard(delta(target: "198.18.0.2:12246", interface: "utun4")))
        XCTAssertFalse(
            filter.shouldDiscard(
                delta(target: "fe80::8af:5f9:677:e110%en0.50231", interface: "en0")
            )
        )
        XCTAssertFalse(filter.shouldDiscard(delta(target: "2408:4004:2000::1:443")))
    }

    func testWildcardAndMissingTargetsAreKept() {
        let filter = TrafficFilter()
        XCTAssertFalse(filter.shouldDiscard(delta(target: "*")))
        XCTAssertFalse(filter.shouldDiscard(delta(target: "*:*")))
        XCTAssertFalse(filter.shouldDiscard(delta(target: nil)))
        XCTAssertFalse(filter.shouldDiscard(delta(target: "*.62849")))
    }

    func testProcessLevelRowsWithoutTargetAreKept() {
        // 兜底路径（旧 -P 风格）产出的 delta 没有接口/目标信息，必须保留。
        let filter = TrafficFilter()
        XCTAssertFalse(filter.shouldDiscard(delta(target: nil, interface: nil)))
    }

    func testHostSeparatorParsing() {
        XCTAssertTrue(TrafficFilter.isLoopbackTarget("127.0.0.1:59169"))
        XCTAssertTrue(TrafficFilter.isLoopbackTarget("127.255.255.255:1"))
        XCTAssertFalse(TrafficFilter.isLoopbackTarget("128.0.0.1:1"))
        XCTAssertFalse(TrafficFilter.isLoopbackTarget("127.0.0.1x:1"))
        XCTAssertFalse(TrafficFilter.isLoopbackTarget(""))
    }
}
