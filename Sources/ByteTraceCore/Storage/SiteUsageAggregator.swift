import Foundation

public final class SiteUsageAggregator: @unchecked Sendable {
    private struct Key: Hashable {
        let day: String
        let bucketStart: Date
        let appKey: String
        let siteKey: String
    }

    private struct Pending {
        var daily: SiteDailyUsageAggregate
        var bucket: SiteBucketUsageAggregate
    }

    private let lock = NSLock()
    private let store: UsageStore
    private let calendar: Calendar
    private let maxPendingEntries: Int
    private var pending: [Key: Pending] = [:]

    public init(
        store: UsageStore,
        calendar: Calendar = .autoupdatingCurrent,
        maxPendingEntries: Int = 20_000
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

    public func discardPending() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    public func ingest(_ delta: SiteUsageDelta) throws {
        guard delta.downloadBytes >= 0, delta.uploadBytes >= 0 else {
            throw UsageAggregatorError.invalidBytes
        }
        guard delta.downloadBytes > 0 || delta.uploadBytes > 0 else { return }

        let day = dayKey(for: delta.sampledAt)
        let bucketStart = calendar.dateInterval(of: .minute, for: delta.sampledAt)?.start
            ?? delta.sampledAt
        let key = Key(
            day: day,
            bucketStart: bucketStart,
            appKey: delta.appKey,
            siteKey: delta.siteKey
        )

        lock.lock()
        defer { lock.unlock() }

        if var existing = pending[key] {
            existing.daily = merge(existing.daily, with: delta)
            existing.bucket = merge(existing.bucket, with: delta)
            pending[key] = existing
            return
        }

        guard pending.count < maxPendingEntries else {
            throw UsageAggregatorError.pendingLimitExceeded
        }

        pending[key] = Pending(
            daily: SiteDailyUsageAggregate(
                day: day,
                appKey: delta.appKey,
                displayName: delta.displayName,
                category: delta.category,
                bundleID: delta.bundleID,
                bundlePath: delta.bundlePath,
                executablePath: delta.executablePath,
                siteKey: delta.siteKey,
                firstSeenAt: delta.sampledAt,
                lastSeenAt: delta.sampledAt,
                downloadBytes: delta.downloadBytes,
                uploadBytes: delta.uploadBytes,
                sampleCount: 1
            ),
            bucket: SiteBucketUsageAggregate(
                bucketStart: bucketStart,
                appKey: delta.appKey,
                displayName: delta.displayName,
                category: delta.category,
                bundleID: delta.bundleID,
                bundlePath: delta.bundlePath,
                executablePath: delta.executablePath,
                siteKey: delta.siteKey,
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

        let values = Array(pending.values)
        guard !values.isEmpty else { return 0 }
        try store.applySiteUsage(
            values.map(\.daily),
            bucketAggregates: values.map(\.bucket)
        )
        pending.removeAll(keepingCapacity: true)
        return values.count
    }

    private func merge(
        _ aggregate: SiteDailyUsageAggregate,
        with delta: SiteUsageDelta
    ) -> SiteDailyUsageAggregate {
        SiteDailyUsageAggregate(
            day: aggregate.day,
            appKey: aggregate.appKey,
            displayName: delta.displayName,
            category: delta.category,
            bundleID: delta.bundleID,
            bundlePath: delta.bundlePath,
            executablePath: delta.executablePath,
            siteKey: aggregate.siteKey,
            firstSeenAt: min(aggregate.firstSeenAt, delta.sampledAt),
            lastSeenAt: max(aggregate.lastSeenAt, delta.sampledAt),
            downloadBytes: saturatingAdd(aggregate.downloadBytes, delta.downloadBytes),
            uploadBytes: saturatingAdd(aggregate.uploadBytes, delta.uploadBytes),
            sampleCount: saturatingAdd(aggregate.sampleCount, 1)
        )
    }

    private func merge(
        _ aggregate: SiteBucketUsageAggregate,
        with delta: SiteUsageDelta
    ) -> SiteBucketUsageAggregate {
        SiteBucketUsageAggregate(
            bucketStart: aggregate.bucketStart,
            appKey: aggregate.appKey,
            displayName: delta.displayName,
            category: delta.category,
            bundleID: delta.bundleID,
            bundlePath: delta.bundlePath,
            executablePath: delta.executablePath,
            siteKey: aggregate.siteKey,
            firstSeenAt: min(aggregate.firstSeenAt, delta.sampledAt),
            lastSeenAt: max(aggregate.lastSeenAt, delta.sampledAt),
            downloadBytes: saturatingAdd(aggregate.downloadBytes, delta.downloadBytes),
            uploadBytes: saturatingAdd(aggregate.uploadBytes, delta.uploadBytes),
            sampleCount: saturatingAdd(aggregate.sampleCount, 1)
        )
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
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
