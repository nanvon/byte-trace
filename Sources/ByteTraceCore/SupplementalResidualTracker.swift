import Foundation

/// 补充通道已关闭连接的残差补记。
///
/// 连接关闭后 nettop 的连接行立刻消失，最后一个采样周期内的字节只留在进程行里。
/// 实测经系统代理用 curl 下载 10 MB：连接行只出现一帧、记到 3.90 MB，
/// 下一帧进程行增量 6.12 MB，合计与 curl 自报一致；只读连接行会漏掉六成。
///
/// 残差 = 进程行增量 − 该进程本帧全部连接行增量（含被过滤的连接）。进程行同时覆盖
/// 回环与未定义接口上的所有套接字，残差本身不带端点，所以只在下列条件下补记：
/// - 该进程最近 `historyWindow` 秒内在补充通道出现过受支持的流量（系统代理 lo0 / TUN）；
/// - 同一窗口内没有出现过会被丢弃的连接（本地 IPC、广播等）；
/// 满足时把残差记到窗口内字节最多的那一类（接口 + 路径）。其余情况不补，宁可少计。
public struct SupplementalResidualTracker: Sendable {
    public static let historyWindow: TimeInterval = 30

    private struct Kind: Hashable, Sendable {
        let interface: String
        let route: TrafficRoute
    }

    private struct KindUsage: Sendable {
        var bytes: Int64
        var lastSeenAt: Date
    }

    private struct History: Sendable {
        var kinds: [Kind: KindUsage] = [:]
        var domains: [String: Date] = [:]
        var lastUnlabeledAt: Date?
        var lastDiscardedAt: Date?
        var lastActiveAt: Date

        func singleDomain(since cutoff: Date) -> String? {
            if let lastUnlabeledAt, lastUnlabeledAt >= cutoff { return nil }
            var onlyDomain: String?
            for (domain, lastSeenAt) in domains where lastSeenAt >= cutoff {
                if onlyDomain != nil { return nil }
                onlyDomain = domain
            }
            return onlyDomain
        }
    }

    private var histories: [String: History] = [:]
    private var framesSincePrune = 0

    public init() {}

    public mutating func reset() {
        histories.removeAll()
        framesSincePrune = 0
    }

    public mutating func discardDomains() {
        histories = histories.mapValues { history in
            var history = history
            history.domains.removeAll()
            // 原有连接仍可能产生残差，先视为域名未知，直到这些连接离开窗口。
            if let lastKnownAt = history.kinds.values.map(\.lastSeenAt).max() {
                history.lastUnlabeledAt = lastKnownAt
            }
            return history
        }
    }

    /// `connections` 是本帧全部非零连接行（过滤前），`processTotals` 是本帧非零进程行。
    public mutating func residuals(
        processTotals: [NettopDelta],
        connections: [NettopDelta],
        proxyEndpoints: Set<NettopEndpoint>,
        at date: Date,
        route: (NettopDelta) -> RouteResolution = { _ in .proxied }
    ) -> [RoutedDelta] {
        let filter = TrafficFilter(proxyEndpoints: proxyEndpoints)
        let cutoff = date.addingTimeInterval(-Self.historyWindow)
        var connectionTotals: [String: (download: Int64, upload: Int64)] = [:]

        for delta in connections {
            let total = connectionTotals[delta.processName] ?? (0, 0)
            connectionTotals[delta.processName] = (
                saturatingAdd(total.download, delta.downloadBytes),
                saturatingAdd(total.upload, delta.uploadBytes)
            )

            var history = histories[delta.processName] ?? History(lastActiveAt: date)
            history.lastActiveAt = date
            let interface: String?
            if filter.shouldKeepLoopback(delta) {
                interface = "lo0"
            } else if filter.shouldKeepTunnel(delta) {
                interface = "utun"
            } else {
                interface = nil
            }
            if let interface {
                let resolution = route(delta)
                let kind = Kind(interface: interface, route: resolution.route)
                var usage = history.kinds[kind] ?? KindUsage(bytes: 0, lastSeenAt: date)
                usage.bytes = saturatingAdd(usage.bytes, saturatingAdd(delta.downloadBytes, delta.uploadBytes))
                usage.lastSeenAt = date
                history.kinds[kind] = usage
                if let domain = resolution.domain {
                    history.domains[domain] = date
                } else {
                    history.lastUnlabeledAt = date
                }
            } else {
                history.lastDiscardedAt = date
            }
            histories[delta.processName] = history
        }

        var residuals: [RoutedDelta] = []
        for total in processTotals {
            let counted = connectionTotals[total.processName] ?? (0, 0)
            let download = max(total.downloadBytes - counted.download, 0)
            let upload = max(total.uploadBytes - counted.upload, 0)
            guard download > 0 || upload > 0,
                  var history = histories[total.processName] else {
                continue
            }
            history.lastActiveAt = date
            histories[total.processName] = history

            if let lastDiscardedAt = history.lastDiscardedAt,
               date.timeIntervalSince(lastDiscardedAt) <= Self.historyWindow {
                continue
            }
            let recentKinds = history.kinds.filter {
                date.timeIntervalSince($0.value.lastSeenAt) <= Self.historyWindow
            }
            guard let dominant = recentKinds.max(by: { $0.value.bytes < $1.value.bytes })?.key else {
                continue
            }
            residuals.append(
                RoutedDelta(
                    delta: NettopDelta(
                        sampledAt: total.sampledAt,
                        processName: total.processName,
                        downloadBytes: download,
                        uploadBytes: upload,
                        interface: dominant.interface
                    ),
                    route: dominant.route,
                    domain: history.singleDomain(since: cutoff)
                )
            )
        }

        framesSincePrune += 1
        if framesSincePrune >= 60 {
            framesSincePrune = 0
            histories = histories.filter { $0.value.lastActiveAt >= cutoff }.mapValues { history in
                var history = history
                history.domains = history.domains.filter { $0.value >= cutoff }
                return history
            }
        }
        return residuals
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
