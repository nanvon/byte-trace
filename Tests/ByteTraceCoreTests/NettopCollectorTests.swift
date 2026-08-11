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

    func testSupplementalCollectorKeepsConnectionDetailsForLoopbackAndUndefinedInterfaces() {
        let arguments = NettopCollectorScope.supplementalConnections.arguments
        XCTAssertFalse(arguments.contains("-P"))
        XCTAssertEqual(values(after: "-t", in: arguments), ["loopback", "undefined"])
        XCTAssertEqual(value(after: "-s", in: arguments), "1")
        XCTAssertEqual(value(after: "-J", in: arguments), "time,interface,state,bytes_in,bytes_out")
    }

    func testDefaultCollectorUsesExternalProcessSummary() {
        XCTAssertEqual(NettopCollector.arguments, NettopCollectorScope.externalProcessSummary.arguments)
    }

    /// `-c` 是 nettop 的低 CPU 模式，实测把补充通道的 CPU 从 9.0% 降到 2.1% 且输出逐字节一致。
    /// 两个通道都必须带上它。
    func testBothCollectorsRequestLowCPUMode() {
        XCTAssertTrue(NettopCollectorScope.externalProcessSummary.arguments.contains("-c"))
        XCTAssertTrue(NettopCollectorScope.supplementalConnections.arguments.contains("-c"))
    }

    private func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private func values(after option: String, in arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == option, arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
    }
}
