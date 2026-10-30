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
        /// 按路径（direct / proxied / proxy_node / proxy_rule_direct）汇总的字节数；
        /// 不含路径统计上线前的数据，代理传输为空。
        let routeBytes: [String: Int64]
    }

    let formatVersion: Int
    let accountingVersion: Int64
    let product: String
    let exportedAt: Date
    let range: Range
    let applicationUsage: [ApplicationUsage]
}
