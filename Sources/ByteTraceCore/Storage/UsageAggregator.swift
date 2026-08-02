import Foundation

public enum UsageAggregatorError: LocalizedError, Equatable {
    case invalidBytes
    case overflow
    case pendingLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidBytes: return "usage bytes must be non-negative"
        case .overflow: return "usage aggregate overflowed Int64"
        case .pendingLimitExceeded: return "usage pending queue reached its limit"
        }
    }
}

public final class UsageAggregator: @unchecked Sendable {
    private struct Key: Hashable {
        let day: String
        let appKey: String
    }

    private struct Pending {
        var delta: DailyUsageAggregate
    }

    private let lock = NSLock()
    private let store: UsageStore
    private let calendar: Calendar
    private let maxPendingEntries: Int
    private var pending: [Key: Pending] = [:]

    public init(
        store: UsageStore,
        calendar: Calendar = .autoupdatingCurrent,
        maxPendingEntries: Int = 10_000
    ) {
        self.store = store
        self.calendar = calendar
        self.maxPendingEntries = max(1, maxPendingEntries)
    }

    public var pendingEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// Discards samples that have not reached SQLite yet. Used only for an
    /// explicit user request to clear all statistics.
    public func discardPending() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func ingest(_ delta: UsageDelta) throws {
        guard delta.downloadBytes >= 0, delta.uploadBytes >= 0 else {
            throw UsageAggregatorError.invalidBytes
        }
        guard delta.downloadBytes > 0 || delta.uploadBytes > 0 else { return }

        let day = dayKey(for: delta.sampledAt)
        let key = Key(day: day, appKey: delta.appKey)

        lock.lock()
        defer { lock.unlock() }

        if var existing = pending[key] {
            existing.delta = try merge(existing.delta, with: delta)
            pending[key] = existing
            return
        }

        guard pending.count < maxPendingEntries else {
            throw UsageAggregatorError.pendingLimitExceeded
        }

        pending[key] = Pending(
            delta: DailyUsageAggregate(
                day: day,
                appKey: delta.appKey,
                displayName: delta.displayName,
                category: delta.category,
                bundleID: delta.bundleID,
                bundlePath: delta.bundlePath,
                executablePath: delta.executablePath,
                firstSeenAt: delta.sampledAt,
                lastSeenAt: delta.sampledAt,
                downloadBytes: delta.downloadBytes,
                uploadBytes: delta.uploadBytes,
                sampleCount: 1
            )
        )
    }

    @discardableResult
    public func flush() throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        let aggregates = pending.values.map(\.delta)
        guard !aggregates.isEmpty else { return 0 }

        try store.apply(aggregates)
        pending.removeAll(keepingCapacity: true)
        return aggregates.count
    }

    private func merge(
        _ aggregate: DailyUsageAggregate,
        with delta: UsageDelta
    ) throws -> DailyUsageAggregate {
        let downloadResult = aggregate.downloadBytes.addingReportingOverflow(delta.downloadBytes)
        let uploadResult = aggregate.uploadBytes.addingReportingOverflow(delta.uploadBytes)
        let sampleResult = aggregate.sampleCount.addingReportingOverflow(1)
        guard !downloadResult.overflow, !uploadResult.overflow, !sampleResult.overflow else {
            throw UsageAggregatorError.overflow
        }

        return DailyUsageAggregate(
            day: aggregate.day,
            appKey: aggregate.appKey,
            displayName: delta.displayName,
            category: delta.category,
            bundleID: delta.bundleID,
            bundlePath: delta.bundlePath,
            executablePath: delta.executablePath,
            firstSeenAt: min(aggregate.firstSeenAt, delta.sampledAt),
            lastSeenAt: max(aggregate.lastSeenAt, delta.sampledAt),
            downloadBytes: downloadResult.partialValue,
            uploadBytes: uploadResult.partialValue,
            sampleCount: sampleResult.partialValue
        )
    }

    private func merge(
        _ aggregate: DailyUsageAggregate,
        with other: DailyUsageAggregate
    ) throws -> DailyUsageAggregate {
        let downloadResult = aggregate.downloadBytes.addingReportingOverflow(other.downloadBytes)
        let uploadResult = aggregate.uploadBytes.addingReportingOverflow(other.uploadBytes)
        let sampleResult = aggregate.sampleCount.addingReportingOverflow(other.sampleCount)
        guard !downloadResult.overflow, !uploadResult.overflow, !sampleResult.overflow else {
            throw UsageAggregatorError.overflow
        }

        return DailyUsageAggregate(
            day: aggregate.day,
            appKey: aggregate.appKey,
            displayName: other.displayName,
            category: other.category,
            bundleID: other.bundleID,
            bundlePath: other.bundlePath,
            executablePath: other.executablePath,
            firstSeenAt: min(aggregate.firstSeenAt, other.firstSeenAt),
            lastSeenAt: max(aggregate.lastSeenAt, other.lastSeenAt),
            downloadBytes: downloadResult.partialValue,
            uploadBytes: uploadResult.partialValue,
            sampleCount: sampleResult.partialValue
        )
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
