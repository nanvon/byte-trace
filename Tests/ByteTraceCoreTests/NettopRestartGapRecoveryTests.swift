import XCTest

@testable import ByteTraceCore

final class NettopRestartGapRecoveryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ name: String, _ download: Int64, _ upload: Int64) -> NettopDelta {
        NettopDelta(sampledAt: "20:00:00.000", processName: name, downloadBytes: download, uploadBytes: upload)
    }

    func testRecoversBytesMissedBetweenSessions() {
        var recovery = NettopRestartGapRecovery()
        recovery.arm()
        XCTAssertEqual(recovery.recover(fromBaseline: [row("Dia.1", 1_000, 100), row("Mail.2", 50, 5)], at: start), [])
        recovery.record([row("Dia.1", 200, 20)], at: start.addingTimeInterval(5))

        let recovered = recovery.recover(
            fromBaseline: [row("Dia.1", 1_500, 130), row("Mail.2", 40, 5), row("New.3", 999, 999)],
            at: start.addingTimeInterval(12)
        )
        XCTAssertEqual(recovered, [row("Dia.1", 300, 10)])
    }

    func testSkipsLongGapsAndNewProcesses() {
        var recovery = NettopRestartGapRecovery()
        recovery.arm()
        _ = recovery.recover(fromBaseline: [row("Dia.1", 1_000, 100)], at: start)
        let recovered = recovery.recover(
            fromBaseline: [row("Dia.1", 5_000, 500)],
            at: start.addingTimeInterval(NettopRestartGapRecovery.maximumGap + 1)
        )
        XCTAssertEqual(recovered, [])

        // 新基线成为参考值，下一次短间隙按它计算。
        XCTAssertEqual(
            recovery.recover(fromBaseline: [row("Dia.1", 5_100, 500)], at: start.addingTimeInterval(70)),
            [row("Dia.1", 100, 0)]
        )
    }

    func testIgnoresFramesOutsideArmedSession() {
        var recovery = NettopRestartGapRecovery()
        XCTAssertEqual(recovery.recover(fromBaseline: [row("Dia.1", 1_000, 100)], at: start), [])

        recovery.arm()
        // arm 之后、首个基线之前到达的旧会话尾帧不能计入参考值。
        recovery.record([row("Dia.1", 10, 10)], at: start)
        _ = recovery.recover(fromBaseline: [row("Dia.1", 1_000, 100)], at: start.addingTimeInterval(1))
        recovery.reset()
        recovery.record([row("Dia.1", 10, 10)], at: start.addingTimeInterval(2))
        XCTAssertEqual(recovery.recover(fromBaseline: [row("Dia.1", 2_000, 200)], at: start.addingTimeInterval(3)), [])
    }

    func testCapsImplausibleJumps() {
        var recovery = NettopRestartGapRecovery()
        recovery.arm()
        _ = recovery.recover(fromBaseline: [row("Dia.1", 0, 0)], at: start)
        let recovered = recovery.recover(fromBaseline: [row("Dia.1", Int64.max, 1)], at: start.addingTimeInterval(2))
        XCTAssertEqual(recovered.first?.downloadBytes, Int64(2 * NettopRestartGapRecovery.maximumBytesPerSecond))
    }
}
