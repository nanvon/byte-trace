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

struct FlowCloseEvent: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let event: String
    let flowID: UUID
    let observedAt: Date
    let startedAt: Date
    let closedAt: Date
    let direction: FlowRecordDirection
    let visibility: FlowRecordVisibility
    let resolvedBundleIdentifier: String?
    let remoteHostname: String?
    let url: String?
    let bytesInbound: UInt64
    let bytesOutbound: UInt64
    let totalBytes: UInt64

    init?(record: FlowRecord, observedAt: Date) {
        guard let closedAt = record.closedAt else {
            return nil
        }

        self.schemaVersion = 1
        self.event = "flow_closed"
        self.flowID = record.flowID
        self.observedAt = observedAt
        self.startedAt = record.startedAt
        self.closedAt = closedAt
        self.direction = record.metadata.direction
        self.visibility = record.metadata.visibility
        self.resolvedBundleIdentifier = record.metadata.resolvedBundleIdentifier
        self.remoteHostname = record.metadata.remoteHostname
        self.url = record.metadata.url
        self.bytesInbound = record.bytesInbound
        self.bytesOutbound = record.bytesOutbound
        self.totalBytes = record.totalBytes
    }

    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case event
        case flowID = "flow_id"
        case observedAt = "observed_at"
        case startedAt = "started_at"
        case closedAt = "closed_at"
        case direction
        case visibility
        case resolvedBundleIdentifier = "resolved_bundle_identifier"
        case remoteHostname = "remote_hostname"
        case url
        case bytesInbound = "bytes_inbound"
        case bytesOutbound = "bytes_outbound"
        case totalBytes = "total_bytes"
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
