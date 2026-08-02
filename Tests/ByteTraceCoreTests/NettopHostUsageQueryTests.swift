import XCTest

@testable import ByteTraceCore

final class NettopHostUsageQueryTests: XCTestCase {
    func testGlobalSummaryMergesVisibleHostsAndBucketsOtherTraffic() {
        let first = Date(timeIntervalSince1970: 100)
        let result = NettopHostUsageQuery.summarize([
            makeRecord(
                at: first,
                appKey: "bundle:one",
                displayName: "One",
                endpointKind: .hostname,
                hostname: "example.com",
                downloadBytes: 100,
                uploadBytes: 10
            ),
            makeRecord(
                at: first.addingTimeInterval(60),
                appKey: "bundle:two",
                displayName: "Two",
                endpointKind: .hostname,
                hostname: "example.com",
                downloadBytes: 20,
                uploadBytes: 2
            ),
            makeRecord(
                at: first,
                appKey: nil,
                displayName: nil,
                endpointKind: .ipAddress,
                hostname: nil,
                downloadBytes: 30,
                uploadBytes: 3
            )
        ], formalTotalBytes: 200)

        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].hostname, "example.com")
        XCTAssertEqual(result.rows[0].totalBytes, 132)
        XCTAssertEqual(result.rows[0].connectionCount, 2)
        XCTAssertNil(result.rows[0].appKey)
        XCTAssertEqual(result.rows[1].label, "无法识别/其他")
        XCTAssertEqual(result.rows[1].totalBytes, 33)
        XCTAssertEqual(result.coverage.visibleHostnameBytes, 132)
        XCTAssertEqual(result.coverage.unrecognizedBytes, 33)
        XCTAssertEqual(result.coverage.observedBytes, 165)
        XCTAssertEqual(result.coverage.observedVisibilityRatio, 132.0 / 165.0, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(result.coverage.formalVisibilityRatio),
            132.0 / 200.0,
            accuracy: 0.0001
        )
    }

    func testApplicationSummaryKeepsApplicationScopeAndPreservesDisplayName() {
        let date = Date(timeIntervalSince1970: 100)
        let result = NettopHostUsageQuery.summarize([
            makeRecord(
                at: date,
                appKey: "bundle:one",
                displayName: "One",
                endpointKind: .hostname,
                hostname: "a.example",
                downloadBytes: 8,
                uploadBytes: 1
            ),
            makeRecord(
                at: date,
                appKey: "bundle:one",
                displayName: "One",
                endpointKind: .unknown,
                hostname: nil,
                downloadBytes: 2,
                uploadBytes: 0
            )
        ], appKey: "bundle:one", formalTotalBytes: 20)

        XCTAssertEqual(result.rows.map(\.appKey), ["bundle:one", "bundle:one"])
        XCTAssertEqual(result.rows.map(\.displayName), ["One", "One"])
        XCTAssertEqual(
            try XCTUnwrap(result.coverage.formalVisibilityRatio),
            9.0 / 20.0,
            accuracy: 0.0001
        )
    }

    func testEmptySummaryHasNoFormalRatioWhenBaselineIsZero() {
        let result = NettopHostUsageQuery.summarize([], formalTotalBytes: 0)

        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.coverage.observedBytes, 0)
        XCTAssertEqual(result.coverage.observedVisibilityRatio, 0)
        XCTAssertNil(result.coverage.formalVisibilityRatio)
    }

    private func makeRecord(
        at date: Date,
        appKey: String?,
        displayName: String?,
        endpointKind: NettopEndpointKind,
        hostname: String?,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) -> NettopHostUsageRecord {
        NettopHostUsageRecord(
            bucketStart: date,
            appKey: appKey,
            displayName: displayName,
            endpointKind: endpointKind,
            hostname: hostname,
            firstSampleAt: date,
            lastSampleAt: date,
            connectionCount: 1,
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes
        )
    }
}
