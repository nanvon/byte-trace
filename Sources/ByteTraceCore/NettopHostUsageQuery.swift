import Foundation

public struct NettopHostUsageRank: Equatable, Sendable {
    public let appKey: String?
    public let displayName: String?
    public let endpointKind: NettopEndpointKind
    public let hostname: String?
    public let firstSampleAt: Date
    public let lastSampleAt: Date
    public let connectionCount: Int64
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public var isVisibleHostname: Bool {
        endpointKind == .hostname && hostname != nil
    }

    public var label: String {
        hostname ?? "无法识别/其他"
    }

    public var totalBytes: Int64 {
        Self.saturatingAdd(downloadBytes, uploadBytes)
    }

    fileprivate init(
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

    fileprivate static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

public struct NettopHostUsageCoverage: Equatable, Sendable {
    public let visibleHostnameBytes: Int64
    public let unrecognizedBytes: Int64
    public let observedBytes: Int64
    public let formalTotalBytes: Int64?

    public var observedVisibilityRatio: Double {
        Self.ratio(numerator: visibleHostnameBytes, denominator: observedBytes) ?? 0
    }

    public var formalVisibilityRatio: Double? {
        guard let formalTotalBytes else { return nil }
        return Self.ratio(numerator: visibleHostnameBytes, denominator: formalTotalBytes)
    }

    fileprivate init(
        visibleHostnameBytes: Int64,
        unrecognizedBytes: Int64,
        formalTotalBytes: Int64?
    ) {
        self.visibleHostnameBytes = visibleHostnameBytes
        self.unrecognizedBytes = unrecognizedBytes
        self.observedBytes = NettopHostUsageRank.saturatingAdd(
            visibleHostnameBytes,
            unrecognizedBytes
        )
        self.formalTotalBytes = formalTotalBytes
    }

    private static func ratio(numerator: Int64, denominator: Int64) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }
}

public struct NettopHostUsageQueryResult: Equatable, Sendable {
    public let rows: [NettopHostUsageRank]
    public let coverage: NettopHostUsageCoverage

    fileprivate init(
        rows: [NettopHostUsageRank],
        coverage: NettopHostUsageCoverage
    ) {
        self.rows = rows
        self.coverage = coverage
    }
}

public enum NettopHostUsageQuery {
    private struct Key: Hashable {
        let endpointKind: NettopEndpointKind
        let hostname: String?
    }

    public static func summarize(
        _ records: [NettopHostUsageRecord],
        appKey: String? = nil,
        formalTotalBytes: Int64? = nil
    ) -> NettopHostUsageQueryResult {
        var rowsByKey: [Key: NettopHostUsageRank] = [:]
        var visibleHostnameBytes: Int64 = 0
        var unrecognizedBytes: Int64 = 0

        for record in records {
            let endpoint = visibleEndpoint(for: record)
            let key = Key(endpointKind: endpoint.kind, hostname: endpoint.hostname)
            let bytes = record.totalBytes
            if endpoint.kind == .hostname {
                visibleHostnameBytes = NettopHostUsageRank.saturatingAdd(
                    visibleHostnameBytes,
                    bytes
                )
            } else {
                unrecognizedBytes = NettopHostUsageRank.saturatingAdd(
                    unrecognizedBytes,
                    bytes
                )
            }

            guard let existing = rowsByKey[key] else {
                rowsByKey[key] = NettopHostUsageRank(
                    appKey: appKey,
                    displayName: appKey == nil ? nil : record.displayName,
                    endpointKind: endpoint.kind,
                    hostname: endpoint.hostname,
                    firstSampleAt: record.firstSampleAt,
                    lastSampleAt: record.lastSampleAt,
                    connectionCount: record.connectionCount,
                    downloadBytes: record.downloadBytes,
                    uploadBytes: record.uploadBytes
                )
                continue
            }

            rowsByKey[key] = NettopHostUsageRank(
                appKey: appKey,
                displayName: appKey == nil ? nil : record.displayName ?? existing.displayName,
                endpointKind: existing.endpointKind,
                hostname: existing.hostname,
                firstSampleAt: min(existing.firstSampleAt, record.firstSampleAt),
                lastSampleAt: max(existing.lastSampleAt, record.lastSampleAt),
                connectionCount: NettopHostUsageRank.saturatingAdd(
                    existing.connectionCount,
                    record.connectionCount
                ),
                downloadBytes: NettopHostUsageRank.saturatingAdd(
                    existing.downloadBytes,
                    record.downloadBytes
                ),
                uploadBytes: NettopHostUsageRank.saturatingAdd(
                    existing.uploadBytes,
                    record.uploadBytes
                )
            )
        }

        let rows = rowsByKey.values.sorted { lhs, rhs in
            if lhs.totalBytes != rhs.totalBytes {
                return lhs.totalBytes > rhs.totalBytes
            }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
        let coverage = NettopHostUsageCoverage(
            visibleHostnameBytes: visibleHostnameBytes,
            unrecognizedBytes: unrecognizedBytes,
            formalTotalBytes: formalTotalBytes.map { max(0, $0) }
        )
        return NettopHostUsageQueryResult(rows: rows, coverage: coverage)
    }

    private static func visibleEndpoint(
        for record: NettopHostUsageRecord
    ) -> (kind: NettopEndpointKind, hostname: String?) {
        guard record.endpointKind == .hostname,
              let hostname = record.hostname,
              !hostname.isEmpty else {
            return (.unknown, nil)
        }
        return (.hostname, hostname)
    }
}
