import XCTest

@testable import ByteTraceCore

final class TrafficFilterTests: XCTestCase {
    private let proxyEndpoint = NettopEndpoint(host: "127.0.0.1", port: 7890)

    private func delta(
        _ process: String = "Dia.1",
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

    func testReducerFiltersAndGroupsByProcessWithSaturation() {
        let reducer = LoopbackTrafficReducer()
        let result = reducer.reduce(
            [
                delta("Dia.1", target: "127.0.0.1:7890", download: Int64.max, upload: 2),
                delta("Dia.1", target: "127.0.0.1:7890", download: 1, upload: 3),
                delta("Dia.1", target: "127.0.0.1:59169", download: 500, upload: 500),
                delta("Drive.2", target: "127.0.0.1:7890", download: 7, upload: 11)
            ],
            proxyEndpoints: [proxyEndpoint]
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].processName, "Dia.1")
        XCTAssertEqual(result[0].downloadBytes, Int64.max)
        XCTAssertEqual(result[0].uploadBytes, 5)
        XCTAssertEqual(result[1].processName, "Drive.2")
        XCTAssertEqual(result[1].downloadBytes, 7)
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
