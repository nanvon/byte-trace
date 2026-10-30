import Foundation
import XCTest

@testable import ByteTraceCore

final class DataDirectoryLockTests: XCTestCase {
    func testSecondHolderIsRejectedUntilRelease() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("byte-trace-lock-\(UUID().uuidString)")
            .appendingPathComponent("collector.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = DataDirectoryLock(url: url)
        let second = DataDirectoryLock(url: url)
        XCTAssertTrue(first.tryAcquire())
        XCTAssertTrue(first.tryAcquire())
        XCTAssertFalse(second.tryAcquire())

        first.release()
        XCTAssertTrue(second.tryAcquire())
        XCTAssertFalse(first.tryAcquire())
        second.release()
    }
}
