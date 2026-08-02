import XCTest

@testable import ByteTraceCore

final class NettopReconciliationTests: XCTestCase {
    func testVisibilityStabilityCountsStatusesAndReconciledRate() {
        let stability = NettopVisibilityStability(
            statuses: [
                .reconciled,
                .partiallyVisible,
                .reconciled,
                .summaryOnly,
                .unknown
            ]
        )

        XCTAssertEqual(stability.sampleCount, 5)
        XCTAssertEqual(stability.reconciledCount, 2)
        XCTAssertEqual(stability.reconciledRate, 0.4, accuracy: 0.001)
        XCTAssertEqual(stability.count(for: .partiallyVisible), 1)
        XCTAssertEqual(stability.count(for: .summaryOnly), 1)
        XCTAssertEqual(stability.count(for: .unknown), 1)
    }

    func testEmptyVisibilityStabilityHasZeroCounts() {
        let stability = NettopVisibilityStability(statuses: [])

        XCTAssertEqual(stability.sampleCount, 0)
        XCTAssertEqual(stability.reconciledCount, 0)
        XCTAssertEqual(stability.reconciledRate, 0)
        XCTAssertEqual(stability.statusCounts.count, NettopVisibilityStatus.allCases.count)
    }

    func testReconciledWhenDifferenceIsWithinFivePercent() {
        let reconciliation = NettopReconciliation(
            summary: NettopByteTotals(downloadBytes: 60_000, uploadBytes: 40_000),
            connections: NettopByteTotals(downloadBytes: 57_600, uploadBytes: 38_400)
        )

        XCTAssertEqual(reconciliation.absoluteDifferenceBytes, 4_000)
        XCTAssertEqual(reconciliation.differencePercent, 4, accuracy: 0.001)
        XCTAssertEqual(reconciliation.allowedDifferenceBytes, 5_000)
        XCTAssertEqual(reconciliation.status, .reconciled)
    }

    func testPartiallyVisibleWhenBothSidesHaveTrafficButDifferenceExceedsThreshold() {
        let reconciliation = NettopReconciliation(
            summary: NettopByteTotals(downloadBytes: 80_000, uploadBytes: 20_000),
            connections: NettopByteTotals(downloadBytes: 72_000, uploadBytes: 18_000)
        )

        XCTAssertEqual(reconciliation.absoluteDifferenceBytes, 10_000)
        XCTAssertEqual(reconciliation.differencePercent, 10, accuracy: 0.001)
        XCTAssertEqual(reconciliation.status, .partiallyVisible)
    }

    func testSummaryOnlyWhenProcessSummaryHasNoConnectionBytes() {
        let reconciliation = NettopReconciliation(
            summary: NettopByteTotals(downloadBytes: 300, uploadBytes: 19_700),
            connections: NettopByteTotals()
        )

        XCTAssertEqual(reconciliation.absoluteDifferenceBytes, 20_000)
        XCTAssertEqual(reconciliation.status, .summaryOnly)
    }

    func testUnknownWhenThereIsNoSummaryOrOnlyUnattributedConnections() {
        XCTAssertEqual(
            NettopReconciliation(
                summary: NettopByteTotals(),
                connections: NettopByteTotals()
            ).status,
            .unknown
        )
        XCTAssertEqual(
            NettopReconciliation(
                summary: NettopByteTotals(),
                connections: NettopByteTotals(downloadBytes: 1, uploadBytes: 2)
            ).status,
            .unknown
        )
    }

    func testMinimumDifferenceThresholdProtectsSmallSamples() {
        let reconciliation = NettopReconciliation(
            summary: NettopByteTotals(downloadBytes: 1_000, uploadBytes: 0),
            connections: NettopByteTotals(downloadBytes: 100, uploadBytes: 0)
        )

        XCTAssertEqual(reconciliation.allowedDifferenceBytes, 1_024)
        XCTAssertEqual(reconciliation.status, .reconciled)
    }
}
