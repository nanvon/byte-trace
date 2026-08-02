import Foundation

public struct NettopByteTotals: Equatable, Sendable {
    public var downloadBytes: Int64
    public var uploadBytes: Int64

    public init(downloadBytes: Int64 = 0, uploadBytes: Int64 = 0) {
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }

    public var totalBytes: Int64 {
        Self.saturatingAdd(downloadBytes, uploadBytes)
    }

    public mutating func add(downloadBytes: Int64, uploadBytes: Int64) {
        self.downloadBytes = Self.saturatingAdd(self.downloadBytes, downloadBytes)
        self.uploadBytes = Self.saturatingAdd(self.uploadBytes, uploadBytes)
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

public enum NettopVisibilityStatus: String, CaseIterable, Sendable {
    case reconciled
    case partiallyVisible = "partially_visible"
    case summaryOnly = "summary_only"
    case unknown
}

public struct NettopVisibilityStability: Equatable, Sendable {
    public let sampleCount: Int
    public let statusCounts: [NettopVisibilityStatus: Int]

    public init(statuses: [NettopVisibilityStatus]) {
        self.sampleCount = statuses.count

        var counts = Dictionary(
            uniqueKeysWithValues: NettopVisibilityStatus.allCases.map { ($0, 0) }
        )
        for status in statuses {
            counts[status, default: 0] += 1
        }
        self.statusCounts = counts
    }

    public var reconciledCount: Int {
        count(for: .reconciled)
    }

    public var reconciledRate: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(reconciledCount) / Double(sampleCount)
    }

    public func count(for status: NettopVisibilityStatus) -> Int {
        statusCounts[status] ?? 0
    }
}

public struct NettopReconciliation: Equatable, Sendable {
    public let summary: NettopByteTotals
    public let connections: NettopByteTotals
    public let absoluteDifferenceBytes: Int64
    public let differencePercent: Double
    public let allowedDifferenceBytes: Int64
    public let status: NettopVisibilityStatus

    public init(
        summary: NettopByteTotals,
        connections: NettopByteTotals,
        allowedDifferenceRatio: Double = 0.05,
        minimumAllowedDifferenceBytes: Int64 = 1024
    ) {
        self.summary = summary
        self.connections = connections

        let difference = Self.absoluteDifference(
            summary.totalBytes,
            connections.totalBytes
        )
        self.absoluteDifferenceBytes = difference

        self.differencePercent = summary.totalBytes == 0
            ? 0
            : Double(difference) / Double(summary.totalBytes) * 100

        let ratio = min(1, max(0, allowedDifferenceRatio))
        let minimum = max(0, minimumAllowedDifferenceBytes)
        let proportionalThreshold: Int64
        if summary.totalBytes <= 0 {
            proportionalThreshold = 0
        } else {
            let proportional = Double(summary.totalBytes) * ratio
            proportionalThreshold = proportional >= Double(Int64.max)
                ? Int64.max
                : Int64(proportional)
        }
        self.allowedDifferenceBytes = max(minimum, proportionalThreshold)

        if summary.totalBytes > 0, connections.totalBytes > 0 {
            self.status = difference <= self.allowedDifferenceBytes
                ? .reconciled
                : .partiallyVisible
        } else if summary.totalBytes > 0 {
            self.status = .summaryOnly
        } else {
            self.status = .unknown
        }
    }

    private static func absoluteDifference(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}
