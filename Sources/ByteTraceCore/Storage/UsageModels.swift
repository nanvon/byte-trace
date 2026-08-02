import Foundation

public struct UsageDelta: Equatable, Sendable {
    public let sampledAt: Date
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let bundleID: String?
    public let bundlePath: String?
    public let executablePath: String?
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
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public struct DailyUsageAggregate: Equatable, Sendable {
    public let day: String
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let bundleID: String?
    public let bundlePath: String?
    public let executablePath: String?
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
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.sampleCount = sampleCount
    }
}
public struct DailyUsageRecord: Equatable, Sendable {
    public let day: String
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let bundleID: String?
    public let bundlePath: String?
    public let executablePath: String?
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
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.sampleCount = sampleCount
    }
}

public struct UsageBucketAggregate: Equatable, Sendable {
    public let bucketStart: Date
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let bundleID: String?
    public let bundlePath: String?
    public let executablePath: String?
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
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.sampleCount = sampleCount
    }
}

public struct UsageBucketRecord: Equatable, Sendable {
    public let bucketStart: Date
    public let appKey: String
    public let displayName: String
    public let category: AppCategory
    public let bundleID: String?
    public let bundlePath: String?
    public let executablePath: String?
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
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.sampleCount = sampleCount
    }
}
