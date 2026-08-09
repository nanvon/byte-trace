import XCTest

@testable import ByteTraceCore

final class NettopCollectorTests: XCTestCase {
    func testArgumentsDoNotFilterLoopback() {
        // 不带 -t 接口过滤：应用走 127.0.0.1 代理的流量在 lo0 上，
        // 过滤回环会让代理环境下的应用统计不到（曾以 -t external 修复虚高、
        // 但误伤真实代理流量，且 macOS 27 下 -t 实测失效）。
        XCTAssertEqual(NettopCollector.arguments.first, "-n")
        XCTAssertFalse(
            NettopCollector.arguments.contains("-t"),
            "采集命令不应带 -t 接口类型过滤，否则代理流量（lo0）统计不到"
        )
    }
}
