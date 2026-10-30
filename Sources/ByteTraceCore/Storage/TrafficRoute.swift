import Foundation

/// 应用侧流量走的路径。代理传输（代理内核的外层连接）不记录路径。
///
/// - `direct`：外部通道采到的非代理进程流量，没有经过本机代理/TUN。
/// - `proxied`：经系统代理（lo0）或 TUN（utun）进入本机代理/VPN，出口规则未知。
/// - `proxyNode` / `proxyRuleDirect`：读取 mihomo 连接表后确认的出口：
///   走代理节点，或命中 DIRECT 规则由代理内核直连。
public enum TrafficRoute: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case direct
    case proxied
    case proxyNode = "proxy_node"
    case proxyRuleDirect = "proxy_rule_direct"

    public var displayName: String {
        switch self {
        case .direct: return "直连"
        case .proxied: return "经代理（出口未知）"
        case .proxyNode: return "经代理 · 节点"
        case .proxyRuleDirect: return "经代理 · 规则直连"
        }
    }

    /// 是否经过本机代理或 TUN。
    public var isProxied: Bool {
        self != .direct
    }
}

public struct RouteUsageAggregate: Equatable, Sendable {
    public let day: String
    public let appKey: String
    public let route: TrafficRoute
    public let lastSeenAt: Date
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(
        day: String,
        appKey: String,
        route: TrafficRoute,
        lastSeenAt: Date,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) {
        self.day = day
        self.appKey = appKey
        self.route = route
        self.lastSeenAt = lastSeenAt
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

/// 一个应用在一段日期内按路径汇总的流量。
public struct RouteUsageRecord: Equatable, Sendable {
    public let appKey: String
    public let route: TrafficRoute
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(appKey: String, route: TrafficRoute, downloadBytes: Int64, uploadBytes: Int64) {
        self.appKey = appKey
        self.route = route
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }

    public var totalBytes: Int64 {
        let result = downloadBytes.addingReportingOverflow(uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}
