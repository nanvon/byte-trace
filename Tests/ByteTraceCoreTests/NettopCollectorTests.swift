import XCTest

@testable import ByteTraceCore

final class NettopCollectorTests: XCTestCase {
    func testExternalCollectorUsesLowPowerProcessSummary() {
        let arguments = NettopCollectorScope.externalProcessSummary.arguments
        XCTAssertTrue(arguments.contains("-P"))
        XCTAssertEqual(value(after: "-t", in: arguments), "external")
        XCTAssertEqual(value(after: "-s", in: arguments), "5")
        XCTAssertEqual(value(after: "-J", in: arguments), "time,interface,state,bytes_in,bytes_out")
    }

    func testLoopbackCollectorKeepsConnectionDetailsOnlyForLoopback() {
        let arguments = NettopCollectorScope.loopbackConnections.arguments
        XCTAssertFalse(arguments.contains("-P"))
        XCTAssertEqual(value(after: "-t", in: arguments), "loopback")
        XCTAssertEqual(value(after: "-s", in: arguments), "1")
        XCTAssertEqual(value(after: "-J", in: arguments), "time,interface,state,bytes_in,bytes_out")
    }

    func testDefaultCollectorUsesExternalProcessSummary() {
        XCTAssertEqual(NettopCollector.arguments, NettopCollectorScope.externalProcessSummary.arguments)
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
