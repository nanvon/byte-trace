import ByteTraceCore
import Foundation

struct ByteTraceExportDocument: Encodable {
    struct Range: Encodable {
        let id: String
        let title: String
        let start: Date
        let end: Date
    }

    struct ApplicationUsage: Encodable {
        let day: String
        let appKey: String
        let displayName: String
        let category: String
        let bundleID: String?
        let bundlePath: String?
        let executablePath: String?
        let downloadBytes: Int64
        let uploadBytes: Int64
        let totalBytes: Int64
        let sampleCount: Int64
    }

    struct HostUsage: Encodable {
        let appKey: String?
        let displayName: String?
        let endpointKind: String
        let hostname: String?
        let firstSampleAt: Date
        let lastSampleAt: Date
        let connectionCount: Int64
        let downloadBytes: Int64
        let uploadBytes: Int64
        let totalBytes: Int64
    }

    struct HostCoverage: Encodable {
        let visibleHostnameBytes: Int64
        let unrecognizedBytes: Int64
        let observedBytes: Int64
        let formalTotalBytes: Int64?
        let observedVisibilityRatio: Double
        let formalVisibilityRatio: Double?
    }

    struct HostExperiment: Encodable {
        let note: String
        let coverage: HostCoverage
        let rows: [HostUsage]
    }

    let formatVersion: Int
    let product: String
    let exportedAt: Date
    let range: Range
    let applicationUsage: [ApplicationUsage]
    let hostnameExperiment: HostExperiment
}
