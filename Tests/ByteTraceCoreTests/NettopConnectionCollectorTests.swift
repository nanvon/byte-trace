import XCTest

@testable import ByteTraceCore

final class NettopConnectionCollectorTests: XCTestCase {
    func testConnectionCollectorUsesNonProcessNumericMode() {
        XCTAssertEqual(
            NettopConnectionCollector.arguments,
            ["-d", "-x", "-L", "0", "-s", "1"]
        )
        XCTAssertFalse(NettopConnectionCollector.arguments.contains("-P"))
        XCTAssertFalse(NettopConnectionCollector.arguments.contains("-n"))
    }
}
