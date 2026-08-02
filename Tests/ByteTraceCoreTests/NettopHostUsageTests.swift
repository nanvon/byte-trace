import XCTest

@testable import ByteTraceCore

final class NettopHostUsageTests: XCTestCase {
    func testSamplesMergeByApplicationAndObservedHostname() throws {
        let first = Date(timeIntervalSince1970: 100)
        let second = first.addingTimeInterval(5)
        var aggregator = NettopHostUsageAggregator()

        try aggregator.ingest(
            NettopHostUsageSample(
                sampledAt: first,
                appKey: "bundle:com.example.app",
                displayName: "Example",
                endpoint: NettopEndpointInfo(kind: .hostname, hostname: "example.com"),
                downloadBytes: 100,
                uploadBytes: 20
            )
        )
        try aggregator.ingest(
            NettopHostUsageSample(
                sampledAt: second,
                appKey: "bundle:com.example.app",
                displayName: "Example Updated",
                endpoint: NettopEndpointInfo(kind: .hostname, hostname: "example.com"),
                downloadBytes: 3,
                uploadBytes: 4
            )
        )
        try aggregator.ingest(
            NettopHostUsageSample(
                sampledAt: second,
                appKey: "bundle:com.example.app",
                displayName: "Example Updated",
                endpoint: NettopEndpointInfo(kind: .hostname, hostname: "cdn.example.com"),
                downloadBytes: 8,
                uploadBytes: 0
            )
        )

        XCTAssertEqual(aggregator.recordCount, 2)
        let records = aggregator.records()
        XCTAssertEqual(records[0].hostname, "example.com")
        XCTAssertEqual(records[0].downloadBytes, 103)
        XCTAssertEqual(records[0].uploadBytes, 24)
        XCTAssertEqual(records[0].connectionCount, 2)
        XCTAssertEqual(records[0].firstSampleAt, first)
        XCTAssertEqual(records[0].lastSampleAt, second)
        XCTAssertEqual(records[0].displayName, "Example Updated")
    }

    func testIPAndUnknownEndpointsRemainSeparateAndExposeNoHostname() throws {
        var aggregator = NettopHostUsageAggregator()
        try aggregator.ingest(
            NettopHostUsageSample(
                sampledAt: Date(timeIntervalSince1970: 100),
                appKey: "process:example",
                endpoint: NettopEndpointInfo(kind: .ipAddress),
                downloadBytes: 10,
                uploadBytes: 0
            )
        )
        try aggregator.ingest(
            NettopHostUsageSample(
                sampledAt: Date(timeIntervalSince1970: 101),
                appKey: "process:example",
                endpoint: NettopEndpointInfo(kind: .unknown),
                downloadBytes: 0,
                uploadBytes: 6
            )
        )

        XCTAssertEqual(aggregator.records().map(\.endpointKind), [.ipAddress, .unknown])
        XCTAssertTrue(aggregator.records().allSatisfy { $0.hostname == nil })
    }

    func testSamplesInDifferentMinutesRemainSeparate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 2, hour: 10, minute: 0, second: 1)
        )!
        let second = first.addingTimeInterval(60)
        var aggregator = NettopHostUsageAggregator(calendar: calendar)

        for sampleDate in [first, second] {
            try aggregator.ingest(
                NettopHostUsageSample(
                    sampledAt: sampleDate,
                    appKey: "bundle:com.example.app",
                    endpoint: NettopEndpointInfo(kind: .hostname, hostname: "example.com"),
                    downloadBytes: 10,
                    uploadBytes: 1
                )
            )
        }

        let records = aggregator.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.downloadBytes), [10, 10])
        XCTAssertEqual(records.map(\.bucketStart), [
            calendar.dateInterval(of: .minute, for: first)!.start,
            calendar.dateInterval(of: .minute, for: second)!.start
        ])
    }

    func testZeroSamplesAreIgnoredAndInvalidOrOverflowingSamplesAreRejected() throws {
        let date = Date(timeIntervalSince1970: 100)
        var aggregator = NettopHostUsageAggregator()

        try aggregator.ingest(
            NettopHostUsageSample(
                sampledAt: date,
                endpoint: NettopEndpointInfo(kind: .hostname, hostname: "example.com"),
                downloadBytes: 0,
                uploadBytes: 0
            )
        )
        XCTAssertEqual(aggregator.recordCount, 0)

        XCTAssertThrowsError(
            try aggregator.ingest(
                NettopHostUsageSample(
                    sampledAt: date,
                    endpoint: NettopEndpointInfo(kind: .hostname, hostname: "example.com"),
                    downloadBytes: -1,
                    uploadBytes: 0
                )
            )
        ) { error in
            XCTAssertEqual(error as? NettopHostUsageError, .invalidBytes)
        }

        try aggregator.ingest(
            NettopHostUsageSample(
                sampledAt: date,
                endpoint: NettopEndpointInfo(kind: .hostname, hostname: "example.com"),
                downloadBytes: Int64.max,
                uploadBytes: 0
            )
        )
        XCTAssertThrowsError(
            try aggregator.ingest(
                NettopHostUsageSample(
                    sampledAt: date,
                    endpoint: NettopEndpointInfo(kind: .hostname, hostname: "example.com"),
                    downloadBytes: 1,
                    uploadBytes: 0
                )
            )
        ) { error in
            XCTAssertEqual(error as? NettopHostUsageError, .overflow)
        }
    }

    func testRemoveAllClearsPendingRecords() throws {
        var aggregator = NettopHostUsageAggregator()
        try aggregator.ingest(
            NettopHostUsageSample(
                sampledAt: Date(timeIntervalSince1970: 100),
                endpoint: NettopEndpointInfo(kind: .hostname, hostname: "example.com"),
                downloadBytes: 1,
                uploadBytes: 0
            )
        )

        aggregator.removeAll()

        XCTAssertEqual(aggregator.recordCount, 0)
        XCTAssertTrue(aggregator.records().isEmpty)
    }
}
