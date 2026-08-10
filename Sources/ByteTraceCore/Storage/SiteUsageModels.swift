import Foundation

public struct SiteUsageDelta: Equatable, Sendable {
    public let sampledAt: Date
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let bundleID: String?
    public let bundlePath: String?
    public let executablePath: String?
    public let siteKey: String
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(
        sampledAt: Date,
        appKey: String,
        displayName: String,
        category: AppCategory,
        bundleID: String? = nil,
        bundlePath: String? = nil,
        executablePath: String? = nil,
        siteKey: String,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) {
        self.sampledAt = sampledAt
        self.appKey = appKey
        self.displayName = displayName
        self.category = category
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.siteKey = siteKey
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public struct SiteDailyUsageAggregate: Equatable, Sendable {
    public let day: String
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let bundleID: String?
    public let bundlePath: String?
    public let executablePath: String?
    public let siteKey: String
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let downloadBytes: Int64
    public let uploadBytes: Int64
    public let sampleCount: Int64

    public init(
        day: String,
        appKey: String,
        displayName: String,
        category: AppCategory,
        bundleID: String?,
        bundlePath: String?,
        executablePath: String?,
        siteKey: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        downloadBytes: Int64,
        uploadBytes: Int64,
        sampleCount: Int64
    ) {
        self.day = day
        self.appKey = appKey
        self.displayName = displayName
        self.category = category
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.siteKey = siteKey
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.sampleCount = sampleCount
    }
}

public struct SiteBucketUsageAggregate: Equatable, Sendable {
    public let bucketStart: Date
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let bundleID: String?
    public let bundlePath: String?
    public let executablePath: String?
    public let siteKey: String
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let downloadBytes: Int64
    public let uploadBytes: Int64
    public let sampleCount: Int64

    public init(
        bucketStart: Date,
        appKey: String,
        displayName: String,
        category: AppCategory,
        bundleID: String?,
        bundlePath: String?,
        executablePath: String?,
        siteKey: String,
        firstSeenAt: Date,
        lastSeenAt: Date,
        downloadBytes: Int64,
        uploadBytes: Int64,
        sampleCount: Int64
    ) {
        self.bucketStart = bucketStart
        self.appKey = appKey
        self.displayName = displayName
        self.category = category
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.siteKey = siteKey
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.sampleCount = sampleCount
    }
}

public struct SiteUsageRecord: Equatable, Sendable {
    public let appKey: String
    public let siteKey: String
    public let downloadBytes: Int64
    public let uploadBytes: Int64
    public let sampleCount: Int64

    public init(
        appKey: String,
        siteKey: String,
        downloadBytes: Int64,
        uploadBytes: Int64,
        sampleCount: Int64
    ) {
        self.appKey = appKey
        self.siteKey = siteKey
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.sampleCount = sampleCount
    }

    public var totalBytes: Int64 {
        let result = downloadBytes.addingReportingOverflow(uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}
