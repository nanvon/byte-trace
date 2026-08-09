import Darwin
import XCTest

@testable import ByteTraceCore

final class TrafficModeDetectorTests: XCTestCase {
    func testCurrentMachineHasDeterministicMode() {
        // 真实系统上检测一次：模式必须是两种之一（不抛错、不崩溃）。
        let detector = TrafficModeDetector()
        let mode = detector.currentMode()
        XCTAssertTrue(mode == .clean || mode == .compatible)
    }

    func testInterfaceNamePrefixDetection() {
        // hasTunnelInterface 只判断前缀；utun0/utun4 均视为隧道接口。
        let detector = TrafficModeDetector()
        let has = detector.hasTunnelInterface()
        XCTAssertEqual(
            has,
            interfaceNames().contains { $0.hasPrefix("utun") },
            "检测结果应与 ifconfig 接口列表一致"
        )
    }

    private func interfaceNames() -> [String] {
        var names: [String] = []
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return names }
        defer { freeifaddrs(addresses) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = addresses
        while let current = cursor {
            if let name = current.pointee.ifa_name {
                names.append(String(cString: name))
            }
            cursor = current.pointee.ifa_next
        }
        return names
    }
}
