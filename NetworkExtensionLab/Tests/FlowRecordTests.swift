import XCTest

final class FlowRecordTests: XCTestCase {
    func testFlowClosePreservesMetadataAndUsesReportBytes() {
        let flowID = UUID()
        let startedAt = Date(timeIntervalSince1970: 100)
        let closedAt = Date(timeIntervalSince1970: 105)
        let metadata = FlowRecordMetadata(
            sourceAppAuditTokenBase64: "audit-token",
            sourceProcessAuditTokenBase64: "process-token",
            resolvedBundleIdentifier: nil,
            remoteHostname: "example.com",
            remoteEndpoint: nil,
            url: nil,
            direction: .outbound
        )
        let store = FlowRecordStore()

        store.begin(
            FlowRecord(
                flowID: flowID,
                startedAt: startedAt,
                metadata: metadata
            )
        )

        let closed = store.close(
            flowID: flowID,
            at: closedAt,
            bytesInbound: 128,
            bytesOutbound: 256
        )

        XCTAssertEqual(closed?.flowID, flowID)
        XCTAssertEqual(closed?.startedAt, startedAt)
        XCTAssertEqual(closed?.closedAt, closedAt)
        XCTAssertEqual(closed?.bytesInbound, 128)
        XCTAssertEqual(closed?.bytesOutbound, 256)
        XCTAssertEqual(closed?.totalBytes, 384)
        XCTAssertEqual(closed?.metadata, metadata)
        XCTAssertEqual(closed?.metadata.visibility, .hostname)
        XCTAssertTrue(closed?.isClosed == true)
    }

    func testUnknownCloseDoesNotCreateARecord() {
        let store = FlowRecordStore()

        let closed = store.close(
            flowID: UUID(),
            at: Date(),
            bytesInbound: 1,
            bytesOutbound: 2
        )

        XCTAssertNil(closed)
        XCTAssertTrue(store.snapshot().isEmpty)
    }

    func testURLHasHigherVisibilityPriorityThanHostname() {
        let metadata = FlowRecordMetadata(
            sourceAppAuditTokenBase64: nil,
            sourceProcessAuditTokenBase64: nil,
            resolvedBundleIdentifier: nil,
            remoteHostname: "example.com",
            remoteEndpoint: nil,
            url: "https://example.com/path",
            direction: .outbound
        )

        XCTAssertEqual(metadata.visibility, .url)
    }

    func testFlowCloseEventEncodesReconciliationFieldsWithoutAuditTokens() throws {
        let flowID = UUID()
        let metadata = FlowRecordMetadata(
            sourceAppAuditTokenBase64: "audit-token",
            sourceProcessAuditTokenBase64: "process-token",
            resolvedBundleIdentifier: "com.example.App",
            remoteHostname: "example.com",
            remoteEndpoint: nil,
            url: "https://example.com/path",
            direction: .outbound
        )
        let record = FlowRecord(
            flowID: flowID,
            startedAt: Date(timeIntervalSince1970: 100),
            metadata: metadata
        ).closing(
            at: Date(timeIntervalSince1970: 105),
            bytesInbound: 128,
            bytesOutbound: 256
        )

        let event = try XCTUnwrap(FlowCloseEvent(record: record, observedAt: Date(timeIntervalSince1970: 106)))
        let line = try event.jsonLine()
        let decoded = try JSONDecoder.flowRecordDecoder.decode(FlowCloseEvent.self, from: Data(line.utf8))

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.event, "flow_closed")
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.totalBytes, 384)
        XCTAssertFalse(line.contains("audit-token"))
        XCTAssertFalse(line.contains("process-token"))
    }
}

private extension JSONDecoder {
    static var flowRecordDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
