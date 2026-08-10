import SystemConfiguration
import XCTest

@testable import ByteTraceCore

final class SystemProxyEndpointMonitorTests: XCTestCase {
    func testEnabledHTTPHTTPSAndSOCKSLoopbackEndpointsAreCollected() {
        let dictionary: [String: Any] = [
            kSCPropNetProxiesHTTPEnable as String: 1,
            kSCPropNetProxiesHTTPProxy as String: "127.0.0.1",
            kSCPropNetProxiesHTTPPort as String: 7890,
            kSCPropNetProxiesHTTPSEnable as String: 1,
            kSCPropNetProxiesHTTPSProxy as String: "localhost",
            kSCPropNetProxiesHTTPSPort as String: 7891,
            kSCPropNetProxiesSOCKSEnable as String: 1,
            kSCPropNetProxiesSOCKSProxy as String: "::1",
            kSCPropNetProxiesSOCKSPort as String: 7892
        ]

        let endpoints = SystemProxyEndpointParser.loopbackEndpoints(from: dictionary)

        XCTAssertEqual(
            endpoints,
            [
                NettopEndpoint(host: "127.0.0.1", port: 7890),
                NettopEndpoint(host: "127.0.0.1", port: 7891),
                NettopEndpoint(host: "::1", port: 7891),
                NettopEndpoint(host: "::1", port: 7892)
            ]
        )
    }

    func testDisabledAndNonLoopbackProxiesAreIgnored() {
        let dictionary: [String: Any] = [
            kSCPropNetProxiesHTTPEnable as String: 0,
            kSCPropNetProxiesHTTPProxy as String: "127.0.0.1",
            kSCPropNetProxiesHTTPPort as String: 7890,
            kSCPropNetProxiesHTTPSEnable as String: 1,
            kSCPropNetProxiesHTTPSProxy as String: "192.168.1.2",
            kSCPropNetProxiesHTTPSPort as String: 8080
        ]

        XCTAssertTrue(SystemProxyEndpointParser.loopbackEndpoints(from: dictionary).isEmpty)
    }
}
