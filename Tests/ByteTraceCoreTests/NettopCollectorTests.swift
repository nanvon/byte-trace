import XCTest

@testable import ByteTraceCore

final class NettopCollectorTests: XCTestCase {
    func testArgumentsExcludeLoopbackInterface() {
        // `-t external` 只统计非回环接口：lo0 回环流量（Electron 本地通信、
        // 代理中转）会虚高且双向对称，曾导致 OpenChamber 单日 12GB+ 虚高。
        XCTAssertEqual(NettopCollector.arguments.first, "-n")
        XCTAssertTrue(
            NettopCollector.arguments.contains("-t"),
            "采集命令必须带 -t 接口类型过滤"
        )
        let externalIndex = NettopCollector.arguments.firstIndex(of: "-t")
        XCTAssertNotNil(externalIndex)
        XCTAssertEqual(
            NettopCollector.arguments[externalIndex! + 1],
            "external",
            "接口类型必须是 external（非回环）"
        )
    }
}
