import Foundation

public enum NettopHostUsageError: LocalizedError, Equatable {
    case invalidBytes
    case overflow

    public var errorDescription: String? {
        switch self {
        case .invalidBytes:
            return "host usage bytes must be non-negative"
        case .overflow:
            return "host usage aggregate overflowed Int64"
        }
    }
}

public struct NettopHostUsageSample: Equatable, Sendable {
    public let sampledAt: Date
    public let appKey: String?
    public let displayName: String?
    public let endpoint: NettopEndpointInfo
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(
        sampledAt: Date,
        appKey: String? = nil,
        displayName: String? = nil,
        endpoint: NettopEndpointInfo,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) {
        self.sampledAt = sampledAt
        self.appKey = appKey
        self.displayName = displayName
        self.endpoint = endpoint
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public struct NettopHostUsageRecord: Equatable, Sendable {
    public let appKey: String?
    public let displayName: String?
    public let endpointKind: NettopEndpointKind
    public let hostname: String?
    public let firstSampleAt: Date
    public let lastSampleAt: Date
    public let connectionCount: Int64
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public var totalBytes: Int64 {
        Self.saturatingAdd(downloadBytes, uploadBytes)
    }

    public init(
        appKey: String?,
        displayName: String?,
        endpointKind: NettopEndpointKind,
        hostname: String?,
        firstSampleAt: Date,
        lastSampleAt: Date,
        connectionCount: Int64,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) {
        self.appKey = appKey
        self.displayName = displayName
        self.endpointKind = endpointKind
        self.hostname = hostname
        self.firstSampleAt = firstSampleAt
        self.lastSampleAt = lastSampleAt
        self.connectionCount = connectionCount
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

public struct NettopHostUsageAggregator: Sendable {
    private struct Key: Hashable, Sendable {
        let appKey: String?
        let endpointKind: NettopEndpointKind
        let hostname: String?
    }

    private var pending: [Key: NettopHostUsageRecord] = [:]

    public init() {}

    public var recordCount: Int {
        pending.count
    }

    public mutating func ingest(_ sample: NettopHostUsageSample) throws {
        guard sample.downloadBytes >= 0, sample.uploadBytes >= 0 else {
            throw NettopHostUsageError.invalidBytes
        }
        guard sample.downloadBytes > 0 || sample.uploadBytes > 0 else { return }

        let endpoint = normalizedEndpoint(sample.endpoint)
        let key = Key(
            appKey: sample.appKey,
            endpointKind: endpoint.kind,
            hostname: endpoint.hostname
        )

        guard let existing = pending[key] else {
            pending[key] = NettopHostUsageRecord(
                appKey: sample.appKey,
                displayName: sample.displayName,
                endpointKind: endpoint.kind,
                hostname: endpoint.hostname,
                firstSampleAt: sample.sampledAt,
                lastSampleAt: sample.sampledAt,
                connectionCount: 1,
                downloadBytes: sample.downloadBytes,
                uploadBytes: sample.uploadBytes
            )
            return
        }

        let downloadResult = existing.downloadBytes.addingReportingOverflow(sample.downloadBytes)
        let uploadResult = existing.uploadBytes.addingReportingOverflow(sample.uploadBytes)
        let connectionResult = existing.connectionCount.addingReportingOverflow(1)
        guard !downloadResult.overflow, !uploadResult.overflow, !connectionResult.overflow else {
            throw NettopHostUsageError.overflow
        }

        pending[key] = NettopHostUsageRecord(
            appKey: existing.appKey,
            displayName: sample.displayName ?? existing.displayName,
            endpointKind: existing.endpointKind,
            hostname: existing.hostname,
            firstSampleAt: min(existing.firstSampleAt, sample.sampledAt),
            lastSampleAt: max(existing.lastSampleAt, sample.sampledAt),
            connectionCount: connectionResult.partialValue,
            downloadBytes: downloadResult.partialValue,
            uploadBytes: uploadResult.partialValue
        )
    }

    public func records() -> [NettopHostUsageRecord] {
        pending.values.sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes {
                return lhs.totalBytes > rhs.totalBytes
            }
            if lhs.appKey != rhs.appKey {
                return (lhs.appKey ?? "") < (rhs.appKey ?? "")
            }
            if lhs.hostname != rhs.hostname {
                return (lhs.hostname ?? "") < (rhs.hostname ?? "")
            }
            return lhs.endpointKind.rawValue < rhs.endpointKind.rawValue
        }
    }

    public mutating func removeAll() {
        pending.removeAll(keepingCapacity: true)
    }

    private func normalizedEndpoint(_ endpoint: NettopEndpointInfo) -> NettopEndpointInfo {
        guard endpoint.kind == .hostname,
              let hostname = endpoint.hostname,
              !hostname.isEmpty else {
            return NettopEndpointInfo(kind: endpoint.kind)
        }
        return NettopEndpointInfo(kind: .hostname, hostname: hostname)
    }
}
