import Foundation
import XCTest
@testable import ByteTraceCore

final class MihomoConnectionsTests: XCTestCase {
    func testFirstSnapshotIsBaselineAndLaterSnapshotsProduceOnlyDeltas() {
        let accumulator = MihomoConnectionAccumulator()
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertTrue(
            accumulator.consume(
                snapshot(connection(id: "a", upload: 10, download: 20)),
                sampledAt: date
            ).isEmpty
        )
        XCTAssertTrue(
            accumulator.consume(
                snapshot(connection(id: "a", upload: 10, download: 20)),
                sampledAt: date
            ).isEmpty
        )

        let deltas = accumulator.consume(
            snapshot(connection(id: "a", upload: 13, download: 27)),
            sampledAt: date
        )
        XCTAssertEqual(
            deltas,
            [
                MihomoConnectionDelta(
                    sampledAt: date,
                    host: "api.github.com",
                    processPath: "/Applications/Browser.app/Contents/MacOS/Browser",
                    downloadBytes: 7,
                    uploadBytes: 3
                )
            ]
        )
    }

    func testNewConnectionsUseCurrentCountersAndDisappearedConnectionsArePruned() {
        let accumulator = MihomoConnectionAccumulator()
        _ = accumulator.consume(snapshot(connection(id: "a", upload: 1, download: 2)))

        let deltas = accumulator.consume(
            snapshot(connection(id: "b", upload: 4, download: 6))
        )
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].uploadBytes, 4)
        XCTAssertEqual(deltas[0].downloadBytes, 6)
        XCTAssertEqual(accumulator.trackedConnectionCount, 1)

        // a 已从上一帧消失；再次出现时视为新连接 ID 的当前可见累计值。
        let reappeared = accumulator.consume(
            snapshot(connection(id: "a", upload: 3, download: 5))
        )
        XCTAssertEqual(reappeared.first?.uploadBytes, 3)
        XCTAssertEqual(reappeared.first?.downloadBytes, 5)
    }

    func testCounterRollbackResetsThatConnectionBaseline() {
        let accumulator = MihomoConnectionAccumulator()
        _ = accumulator.consume(snapshot(connection(id: "a", upload: 10, download: 20)))

        XCTAssertTrue(
            accumulator.consume(
                snapshot(connection(id: "a", upload: 2, download: 3))
            ).isEmpty
        )
        let deltas = accumulator.consume(
            snapshot(connection(id: "a", upload: 5, download: 9))
        )
        XCTAssertEqual(deltas.first?.uploadBytes, 3)
        XCTAssertEqual(deltas.first?.downloadBytes, 6)
    }

    func testResetRequiresANewBaselineAndInvalidCountersAreIgnored() {
        let accumulator = MihomoConnectionAccumulator(maxTrackedConnections: 1)
        _ = accumulator.consume(snapshot(connection(id: "a", upload: 1, download: 1)))
        accumulator.reset()
        XCTAssertTrue(
            accumulator.consume(snapshot(connection(id: "a", upload: 9, download: 9))).isEmpty
        )

        let invalid = MihomoConnection(
            id: "invalid",
            metadata: .init(host: "example.com", processPath: nil),
            uploadBytes: -1,
            downloadBytes: nil
        )
        XCTAssertTrue(accumulator.consume(snapshot(invalid)).isEmpty)
        XCTAssertEqual(accumulator.trackedConnectionCount, 0)
    }

    func testDecoderToleratesMalformedOptionalConnectionFields() throws {
        let data = Data(
            #"{"connections":[{"id":"a","metadata":{"host":"example.com"},"upload":"bad","download":12}]}"#.utf8
        )
        let decoded = try JSONDecoder().decode(MihomoConnectionSnapshot.self, from: data)
        XCTAssertEqual(decoded.connections.count, 1)
        XCTAssertNil(decoded.connections[0].uploadBytes)
        XCTAssertEqual(decoded.connections[0].downloadBytes, 12)
    }

    func testMalformedFrameForKnownConnectionKeepsPreviousBaseline() {
        let accumulator = MihomoConnectionAccumulator()
        _ = accumulator.consume(snapshot(connection(id: "a", upload: 10, download: 20)))

        let malformed = MihomoConnection(
            id: "a",
            metadata: .init(host: "api.github.com", processPath: nil),
            uploadBytes: nil,
            downloadBytes: 25
        )
        XCTAssertTrue(accumulator.consume(snapshot(malformed)).isEmpty)

        let deltas = accumulator.consume(
            snapshot(connection(id: "a", upload: 14, download: 27))
        )
        XCTAssertEqual(deltas.first?.uploadBytes, 4)
        XCTAssertEqual(deltas.first?.downloadBytes, 7)
    }

    func testTrackingCacheHonorsConfiguredLimit() {
        let accumulator = MihomoConnectionAccumulator(maxTrackedConnections: 1)
        _ = accumulator.consume(
            snapshot(
                connection(id: "a", upload: 1, download: 1),
                connection(id: "b", upload: 2, download: 2)
            )
        )
        XCTAssertEqual(accumulator.trackedConnectionCount, 1)
    }

    private func snapshot(_ connections: MihomoConnection...) -> MihomoConnectionSnapshot {
        MihomoConnectionSnapshot(connections: connections)
    }

    private func connection(
        id: String,
        upload: Int64,
        download: Int64
    ) -> MihomoConnection {
        MihomoConnection(
            id: id,
            metadata: .init(
                host: "api.github.com",
                processPath: "/Applications/Browser.app/Contents/MacOS/Browser"
            ),
            uploadBytes: upload,
            downloadBytes: download
        )
    }
}
