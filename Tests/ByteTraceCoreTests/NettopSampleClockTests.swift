import Foundation
import XCTest

@testable import ByteTraceCore

final class NettopSampleClockTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    func testSameDayClockIsGraftedOntoNow() {
        let now = date(30, 12, 0, 5)
        XCTAssertEqual(
            NettopSampleClock.date(for: "12:00:00.500000", relativeTo: now, calendar: calendar),
            date(30, 12, 0, 0).addingTimeInterval(0.5)
        )
    }

    func testFrameFromBeforeMidnightStaysOnPreviousDay() {
        let now = date(31, 0, 0, 2)
        XCTAssertEqual(
            NettopSampleClock.date(for: "23:59:58.000000", relativeTo: now, calendar: calendar),
            date(30, 23, 59, 58)
        )
    }

    func testInvalidClockFallsBackToNow() {
        let now = date(30, 8, 0, 0)
        XCTAssertEqual(NettopSampleClock.date(for: "bad", relativeTo: now, calendar: calendar), now)
    }
}
