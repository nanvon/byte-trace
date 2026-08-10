import XCTest

@testable import ByteTraceCore

final class TrafficFilterTests: XCTestCase {
    private let proxyEndpoint = NettopEndpoint(host: "127.0.0.1", port: 7890)

    private func delta(
        _ process: String = "Dia.1",
        source: String? = "127.0.0.1:57123",
        target: String?,
        interface: String? = "lo0",
        download: Int64 = 100,
        upload: Int64 = 200
    ) -> NettopDelta {
        NettopDelta(
            sampledAt: "20:00:00.000",
            processName: process,
            downloadBytes: download,
            uploadBytes: upload,
            interface: interface,
            connectionTarget: target,
            localEndpoint: source.flatMap(NettopEndpoint.parse),
            remoteEndpoint: target.flatMap(NettopEndpoint.parse)
        )
    }

    func testSystemProxyLoopbackEndpointIsKept() {
        let filter = TrafficFilter(proxyEndpoints: [proxyEndpoint])
        XCTAssertTrue(filter.shouldKeepLoopback(delta(target: "127.0.0.1:7890")))
        XCTAssertFalse(filter.shouldDiscard(delta(target: "127.0.0.1:7890")))
    }

    func testOtherLoopbackEndpointsAreDiscarded() {
        let filter = TrafficFilter(proxyEndpoints: [proxyEndpoint])
        XCTAssertTrue(filter.shouldDiscard(delta(target: "127.0.0.1:59169")))
        XCTAssertTrue(filter.shouldDiscard(delta(target: "[::1]:9090")))
    }

    func testNonLoopbackAndMissingEndpointsAreNotAcceptedByLoopbackLane() {
        let filter = TrafficFilter(proxyEndpoints: [proxyEndpoint])
        XCTAssertTrue(filter.shouldDiscard(delta(target: "91.108.56.139:443", interface: "en0")))
        XCTAssertTrue(filter.shouldDiscard(delta(target: nil)))
    }

    func testConcreteTunnelConnectionIsKept() {
        let filter = TrafficFilter(proxyEndpoints: [proxyEndpoint])
        let telegram = delta(
            "Telegram.53534",
            source: "198.18.0.1:58583",
            target: "91.108.56.139:443",
            interface: "utun4"
        )

        XCTAssertTrue(filter.shouldKeepTunnel(telegram))
        XCTAssertFalse(filter.shouldDiscard(telegram))
    }

    func testTunnelWildcardBroadcastAndPhysicalConnectionsAreDiscarded() {
        let filter = TrafficFilter(proxyEndpoints: [proxyEndpoint])

        XCTAssertTrue(
            filter.shouldDiscard(
                delta(source: nil, target: nil, interface: "utun4")
            )
        )
        XCTAssertTrue(
            filter.shouldDiscard(
                delta(source: "198.18.0.1:5353", target: "*:*", interface: "utun4")
            )
        )
        XCTAssertTrue(
            filter.shouldDiscard(
                delta(source: "192.168.1.2:50000", target: "91.108.56.139:443", interface: "en0")
            )
        )
    }

    func testReducerFiltersAndGroupsByProcessAndSourceWithSaturation() {
        let reducer = SupplementalTrafficReducer()
        let result = reducer.reduce(
            [
                delta("Dia.1", target: "127.0.0.1:7890", download: Int64.max, upload: 2),
                delta("Dia.1", target: "127.0.0.1:7890", download: 1, upload: 3),
                delta("Dia.1", target: "127.0.0.1:59169", download: 500, upload: 500),
                delta("Drive.2", target: "127.0.0.1:7890", download: 7, upload: 11),
                delta(
                    "Dia.1",
                    source: "198.18.0.1:59051",
                    target: "91.108.56.139:443",
                    interface: "utun4",
                    download: 13,
                    upload: 17
                )
            ],
            proxyEndpoints: [proxyEndpoint]
        )

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].processName, "Dia.1")
        XCTAssertEqual(result[0].interface, "lo0")
        XCTAssertEqual(result[0].downloadBytes, Int64.max)
        XCTAssertEqual(result[0].uploadBytes, 5)
        XCTAssertEqual(result[1].processName, "Drive.2")
        XCTAssertEqual(result[1].downloadBytes, 7)
        XCTAssertEqual(result[2].processName, "Dia.1")
        XCTAssertEqual(result[2].interface, "utun")
        XCTAssertEqual(result[2].downloadBytes, 13)
        XCTAssertEqual(result[2].uploadBytes, 17)
    }

    func testTunnelTrafficStillWorksWithoutSystemProxyEndpoints() {
        let reducer = SupplementalTrafficReducer()
        let result = reducer.reduce(
            [
                delta(
                    "Telegram.53534",
                    source: "198.18.0.1:58583",
                    target: "91.108.56.139:443",
                    interface: "utun4"
                )
            ],
            proxyEndpoints: []
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.processName, "Telegram.53534")
        XCTAssertEqual(result.first?.interface, "utun")
    }

    func testProxyTunnelMirrorIsDiscardedAfterAttribution() throws {
        let tunnel = delta(
            "mihomo.78366",
            source: "198.18.0.1:51475",
            target: "198.18.0.2:20252",
            interface: "utun4"
        )
        let reduced = SupplementalTrafficReducer().reduce([tunnel], proxyEndpoints: [])

        XCTAssertEqual(reduced.count, 1)
        XCTAssertFalse(
            TrafficFilter.shouldKeepAfterAttribution(
                try XCTUnwrap(reduced.first),
                category: .proxyTransport
            )
        )
        XCTAssertTrue(
            TrafficFilter.shouldKeepAfterAttribution(
                try XCTUnwrap(reduced.first),
                category: .userApp
            )
        )
    }

    func testEndpointParsingAndLoopbackDetection() {
        XCTAssertEqual(
            NettopEndpoint.parse("127.0.0.1:7890"),
            NettopEndpoint(host: "127.0.0.1", port: 7890)
        )
        XCTAssertEqual(
            NettopEndpoint.parse("::1.7890"),
            NettopEndpoint(host: "::1", port: 7890)
        )
        XCTAssertEqual(
            NettopEndpoint.parse("[::1]:7890"),
            NettopEndpoint(host: "::1", port: 7890)
        )
        XCTAssertTrue(TrafficFilter.isLoopbackTarget("127.255.255.255:1"))
        XCTAssertTrue(TrafficFilter.isLoopbackTarget("::1.8021"))
        XCTAssertFalse(TrafficFilter.isLoopbackTarget("::10.8021"))
        XCTAssertFalse(TrafficFilter.isLoopbackTarget("128.0.0.1:1"))
        XCTAssertFalse(NettopEndpoint(host: "127.invalid.address.value", port: 1).isLoopback)
    }
}
