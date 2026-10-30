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

    func testProcessArgumentsOfCurrentProcess() throws {
        let arguments = try XCTUnwrap(MihomoControllerDiscovery.processArguments(pid: getpid()))
        XCTAssertEqual(arguments.count, CommandLine.arguments.count)
    }
}
