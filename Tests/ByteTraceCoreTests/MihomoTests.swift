import Foundation
import XCTest

@testable import ByteTraceCore

final class MihomoTests: XCTestCase {
    func testControllerFromArgumentsWins() {
        let controller = MihomoControllerDiscovery.controller(
            arguments: ["-d", "/tmp/x", "-ext-ctl", "127.0.0.1:9090", "-secret", "abc"],
            readFile: { _ in "external-controller: 127.0.0.1:9999\nsecret: other\n" }
        )
        XCTAssertEqual(controller, MihomoController(transport: .tcp(host: "127.0.0.1", port: 9090), secret: "abc"))
    }

    func testControllerFromConfigFile() {
        let yaml = """
        mixed-port: 7890
        # comment: x
        external-controller: '0.0.0.0:9097'  # 局域网
        secret: "s3"
        tun:
          external-controller: 1.2.3.4:1
        """
        let controller = MihomoControllerDiscovery.controller(
            arguments: ["-f", "/tmp/config.yaml"],
            readFile: { $0 == "/tmp/config.yaml" ? yaml : nil }
        )
        XCTAssertEqual(controller, MihomoController(transport: .tcp(host: "127.0.0.1", port: 9097), secret: "s3"))
    }

    func testUnixControllerAndMissingController() {
        XCTAssertEqual(
            MihomoControllerDiscovery.controller(arguments: ["-ext-ctl-unix", "/tmp/verge/verge-mihomo.sock"], readFile: { _ in nil }),
            MihomoController(transport: .unix(path: "/tmp/verge/verge-mihomo.sock"), secret: nil)
        )
        XCTAssertNil(MihomoControllerDiscovery.controller(arguments: ["-d", "/tmp"], readFile: { _ in "port: 1\n" }))
    }

    func testConnectionsParseRoutesFromChains() throws {
        let json = """
        {"downloadTotal": 10, "uploadTotal": 5, "connections": [
          {"id": "a", "metadata": {"sourceIP": "127.0.0.1", "sourcePort": "50001"}, "upload": 1, "download": 2, "chains": ["日本 01", "AI"]},
          {"id": "b", "metadata": {"sourceIP": "198.18.0.1", "sourcePort": "60099"}, "upload": 1, "download": 2, "chains": ["DIRECT"]},
          {"id": "c", "metadata": {"sourceIP": "", "sourcePort": "1"}, "chains": ["DIRECT"]},
          {"id": "d", "metadata": {"sourceIP": "127.0.0.1", "sourcePort": "50002"}, "chains": ["REJECT"]}
        ]}
        """
        let snapshot = try MihomoConnectionsParser.parse(Data(json.utf8))
        XCTAssertEqual(snapshot.downloadTotal, 10)
        XCTAssertEqual(snapshot.connections.map(\.route), [.proxyNode, .proxyRuleDirect, .proxied])

        let tracker = MihomoRouteTracker(retention: 60)
        let now = Date()
        tracker.update(with: snapshot, at: now)
        XCTAssertEqual(tracker.route(forLocalEndpoint: NettopEndpoint(host: "198.18.0.1", port: 60099)), .proxyRuleDirect)
        XCTAssertEqual(tracker.route(forLocalEndpoint: NettopEndpoint(host: "127.0.0.1", port: 50001)), .proxyNode)
        XCTAssertNil(tracker.route(forLocalEndpoint: NettopEndpoint(host: "127.0.0.1", port: 59999)))

        tracker.update(with: MihomoConnectionsSnapshot(downloadTotal: 0, uploadTotal: 0, connections: []), at: now.addingTimeInterval(61))
        XCTAssertNil(tracker.route(forLocalEndpoint: NettopEndpoint(host: "127.0.0.1", port: 50001)))
    }

    func testHTTPResponseBodyHandlesChunkedEncoding() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n3\r\n:1}\r\n0\r\n\r\n"
        XCTAssertEqual(try MihomoClient.body(ofHTTPResponse: Data(raw.utf8)), Data("{\"a\":1}".utf8))

        let unauthorized = "HTTP/1.0 401 Unauthorized\r\n\r\n{}"
        XCTAssertThrowsError(try MihomoClient.body(ofHTTPResponse: Data(unauthorized.utf8))) {
            XCTAssertEqual($0 as? MihomoClientError, .unauthorized)
        }
    }

    func testCacheExpiresOnReadAndKeepsClosedConnectionsWithinRetention() {
        let tracker = MihomoRouteTracker(retention: 60)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let endpoint = NettopEndpoint(host: "127.0.0.1", port: 50001)
        let connection = MihomoConnection(id: "a", source: endpoint, route: .proxyNode, downloadBytes: 0, uploadBytes: 0)
        tracker.update(with: MihomoConnectionsSnapshot(downloadTotal: 0, uploadTotal: 0, connections: [connection]), at: now)
        tracker.update(with: MihomoConnectionsSnapshot(downloadTotal: 0, uploadTotal: 0, connections: []), at: now.addingTimeInterval(1))
        XCTAssertEqual(tracker.route(forLocalEndpoint: endpoint, at: now.addingTimeInterval(60)), .proxyNode)
        XCTAssertNil(tracker.route(forLocalEndpoint: endpoint, at: now.addingTimeInterval(61)))
        tracker.removeAll()
        XCTAssertNil(tracker.route(forLocalEndpoint: endpoint, at: now.addingTimeInterval(2)))
    }

    func testConflictingRoutesForSameEndpointRemainUnknown() throws {
        let snapshot = try MihomoConnectionsParser.parse(Data("""
        {"connections": [
          {"metadata":{"sourceIP":"127.0.0.1","sourcePort":"50001","host":"a.example.com"},"chains":["node"]},
          {"metadata":{"sourceIP":"127.0.0.1","sourcePort":"50001","host":"b.example.com"},"chains":["DIRECT"]},
          {"metadata":{"sourceIP":"127.0.0.1","sourcePort":"50001","host":"c.example.com"},"chains":["PASS"]}
        ]}
        """.utf8), includeDomains: true)
        let tracker = MihomoRouteTracker()
        tracker.update(with: snapshot)
        let endpoint = NettopEndpoint(host: "127.0.0.1", port: 50001)
        XCTAssertEqual(tracker.resolution(forLocalEndpoint: endpoint), .proxied)
    }

    func testParsesDomainFallbackAndPreservesAgreedMetadata() throws {
        let data = Data("""
        {"connections": [
          {"metadata":{"sourceIP":"127.0.0.1","sourcePort":"50001","host":"www.Example.com","sniffHost":"other.com"},"chains":[" node "]},
          {"metadata":{"sourceIP":"127.0.0.1","sourcePort":"50001","host":"1.2.3.4","sniffHost":"api.example.com"},"chains":["other node"]},
          {"metadata":{"sourceIP":"127.0.0.1","sourcePort":"50002","host":"","sniffHost":"news.example.co.uk"},"chains":["DIRECT"]},
          {"metadata":{"sourceIP":"127.0.0.1","sourcePort":"50002","host":"other.co.uk"},"chains":["DIRECT"]}
        ]}
        """.utf8)
        XCTAssertTrue(try MihomoConnectionsParser.parse(data).connections.allSatisfy { $0.domain == nil })
        let snapshot = try MihomoConnectionsParser.parse(data, includeDomains: true)
        XCTAssertEqual(snapshot.connections.map(\.domain), ["example.com", "example.com", "example.co.uk", "other.co.uk"])
        XCTAssertEqual(snapshot.connections.map(\.exitName), ["node", "other node", nil, nil])

        let tracker = MihomoRouteTracker()
        tracker.update(with: snapshot)
        let nodeEndpoint = NettopEndpoint(host: "127.0.0.1", port: 50001)
        XCTAssertEqual(tracker.resolution(forLocalEndpoint: nodeEndpoint), RouteResolution(route: .proxyNode, domain: "example.com"))
        let directEndpoint = NettopEndpoint(host: "127.0.0.1", port: 50002)
        XCTAssertEqual(tracker.resolution(forLocalEndpoint: directEndpoint), RouteResolution(route: .proxyRuleDirect))

        tracker.discardDomains()
        XCTAssertEqual(tracker.resolution(forLocalEndpoint: nodeEndpoint), RouteResolution(route: .proxyNode))
        XCTAssertEqual(tracker.route(forLocalEndpoint: directEndpoint), .proxyRuleDirect)
    }

    func testProcessArgumentsOfCurrentProcess() throws {
        let arguments = try XCTUnwrap(MihomoControllerDiscovery.processArguments(pid: getpid()))
        XCTAssertEqual(arguments.count, CommandLine.arguments.count)
    }
}
