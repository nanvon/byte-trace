import Foundation

enum FlowRecordDirection: String, Codable, Sendable {
    case inbound
    case outbound
    case unknown
}

enum FlowRecordVisibility: String, Codable, Sendable {
    case url
    case hostname
    case auditTokenOnly
    case unknown
}

struct FlowRecordMetadata: Codable, Equatable, Sendable {
    let sourceAppAuditTokenBase64: String?
    let sourceProcessAuditTokenBase64: String?
    let resolvedBundleIdentifier: String?
    let remoteHostname: String?
    let remoteEndpoint: String?
    let url: String?
    let direction: FlowRecordDirection

    var visibility: FlowRecordVisibility {
        if url != nil {
            return .url
        }
        if remoteHostname != nil {
            return .hostname
        }
        if sourceAppAuditTokenBase64 != nil || sourceProcessAuditTokenBase64 != nil {
            return .auditTokenOnly
        }
        return .unknown
    }
}

struct FlowRecord: Codable, Equatable, Sendable {
    let flowID: UUID
    let startedAt: Date
    let metadata: FlowRecordMetadata
    let closedAt: Date?
    let bytesInbound: UInt64
    let bytesOutbound: UInt64

    init(
        flowID: UUID,
        startedAt: Date,
        metadata: FlowRecordMetadata,
        closedAt: Date? = nil,
        bytesInbound: UInt64 = 0,
        bytesOutbound: UInt64 = 0
    ) {
        self.flowID = flowID
        self.startedAt = startedAt
        self.metadata = metadata
        self.closedAt = closedAt
        self.bytesInbound = bytesInbound
        self.bytesOutbound = bytesOutbound
    }

    var isClosed: Bool {
        closedAt != nil
    }

    var totalBytes: UInt64 {
        bytesInbound + bytesOutbound
    }

    func closing(
        at closedAt: Date,
        bytesInbound: UInt64,
        bytesOutbound: UInt64
    ) -> FlowRecord {
        FlowRecord(
            flowID: flowID,
            startedAt: startedAt,
            metadata: metadata,
            closedAt: closedAt,
            bytesInbound: bytesInbound,
            bytesOutbound: bytesOutbound
        )
    }
}

final class FlowRecordStore: @unchecked Sendable {
    private let lock = NSLock()
    private var openRecords: [UUID: FlowRecord] = [:]
    private var closedRecords: [FlowRecord] = []

    func begin(_ record: FlowRecord) {
        lock.lock()
        defer { lock.unlock() }
        openRecords[record.flowID] = record
    }

    @discardableResult
    func close(
        flowID: UUID,
        at closedAt: Date,
        bytesInbound: UInt64,
        bytesOutbound: UInt64
    ) -> FlowRecord? {
        lock.lock()
        defer { lock.unlock() }

        guard let openRecord = openRecords.removeValue(forKey: flowID) else {
            return nil
        }

        let closedRecord = openRecord.closing(
            at: closedAt,
            bytesInbound: bytesInbound,
            bytesOutbound: bytesOutbound
        )
        closedRecords.append(closedRecord)
        return closedRecord
    }

    func snapshot() -> [FlowRecord] {
        lock.lock()
        defer { lock.unlock() }
        return closedRecords
    }
}
