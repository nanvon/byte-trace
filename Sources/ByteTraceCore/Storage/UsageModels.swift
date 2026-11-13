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
    /// 应用侧流量的路径；代理传输为 nil，不记录路径。
    public let route: TrafficRoute?
    /// 宿主之下的程序；nil 为宿主应用自身。
    public let program: AttributedProgram?
    public let domain: String?

    public var programKey: String { program?.key ?? "" }

    public init(
        sampledAt: Date,
        appKey: String,
        displayName: String,
        category: AppCategory,
        bundleID: String? = nil,
        bundlePath: String? = nil,
        executablePath: String? = nil,
        downloadBytes: Int64,
        uploadBytes: Int64,
        route: TrafficRoute? = nil,
        program: AttributedProgram? = nil,
        domain: String? = nil
    ) {
        self.route = route
        self.program = program
        self.domain = domain
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

public struct DomainUsageAggregate: Equatable, Sendable {
    public let day: String
    public let appKey: String
    public let domain: String
    public let route: TrafficRoute
    public let lastSeenAt: Date
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(day: String, appKey: String, domain: String, route: TrafficRoute, lastSeenAt: Date,
                downloadBytes: Int64, uploadBytes: Int64) {
        self.day = day
        self.appKey = appKey
        self.domain = domain
        self.route = route
        self.lastSeenAt = lastSeenAt
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public struct DomainUsageRecord: Equatable, Sendable {
    public let appKey: String
    public let domain: String
    public let route: TrafficRoute
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(appKey: String, domain: String, route: TrafficRoute, downloadBytes: Int64, uploadBytes: Int64) {
        self.appKey = appKey
        self.domain = domain
        self.route = route
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public struct DailyUsageAggregate: Equatable, Sendable {
    public let day: String
    public let appKey: String
    public let program: AttributedProgram?

    public var programKey: String { program?.key ?? "" }
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
        sampleCount: Int64,
        program: AttributedProgram? = nil
    ) {
        self.day = day
        self.appKey = appKey
        self.program = program
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
    public let program: AttributedProgram?

    public var programKey: String { program?.key ?? "" }
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
        sampleCount: Int64,
        program: AttributedProgram? = nil
    ) {
        self.bucketStart = bucketStart
        self.appKey = appKey
        self.program = program
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

/// Aggregated usage for one app over a bucket-backed time range.
/// `firstBucketStart` preserves the existing range record day semantics without
/// materializing every app-minute row in the application process.
public struct UsageBucketSummaryRecord: Equatable, Sendable {
    public let firstBucketStart: Date
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
        firstBucketStart: Date,
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
        self.firstBucketStart = firstBucketStart
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

/// Minimal minute-level data used by total and per-app charts.
public struct UsageTimelineRecord: Equatable, Sendable {
    public let bucketStart: Date
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(bucketStart: Date, downloadBytes: Int64, uploadBytes: Int64) {
        self.bucketStart = bucketStart
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

/// One app's traffic within one fixed-length time slot, used by stacked per-app charts.
public struct UsageAppTimelineRecord: Equatable, Sendable {
    public let slotStart: Date
    public let appKey: String
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(slotStart: Date, appKey: String, downloadBytes: Int64, uploadBytes: Int64) {
        self.slotStart = slotStart
        self.appKey = appKey
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public struct UsageBucketStats: Equatable, Sendable {
    public let bucketCount: Int64
    public let earliestBucket: Date?
    public let latestBucket: Date?

    public init(
        bucketCount: Int64,
        earliestBucket: Date?,
        latestBucket: Date?
    ) {
        self.bucketCount = bucketCount
        self.earliestBucket = earliestBucket
        self.latestBucket = latestBucket
    }
}

/// 某个宿主下某个程序在一段时间内的流量（不含代理传输）。`programKey` 为空表示宿主应用自身。
/// 日汇总查询按天返回；分钟桶查询把整个时间段合成一行，`day` 取第一个分钟桶所在日。
public struct ProgramUsageRecord: Equatable, Sendable {
    public let day: String
    public let appKey: String
    public let programKey: String
    public let programName: String?
    public let programCategory: AppCategory?
    public let programExecutablePath: String?
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(
        day: String,
        appKey: String,
        programKey: String,
        programName: String?,
        programCategory: AppCategory?,
        programExecutablePath: String?,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) {
        self.day = day
        self.appKey = appKey
        self.programKey = programKey
        self.programName = programName
        self.programCategory = programCategory
        self.programExecutablePath = programExecutablePath
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }

    /// 跨宿主汇总时的程序身份：应用自身以宿主 appKey 出现。
    public var programIdentity: String {
        programKey.isEmpty ? appKey : programKey
    }

    public var totalBytes: Int64 {
        let result = downloadBytes.addingReportingOverflow(uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}

/// 运行时记下的「nettop 进程名 → 宿主 + 程序」。
public struct ProcessNameAttribution: Hashable, Sendable {
    public let appKey: String
    public let programKey: String

    public init(appKey: String, programKey: String) {
        self.appKey = appKey
        self.programKey = programKey
    }
}
