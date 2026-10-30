import Foundation

/// 补充通道同时接收 `loopback` 与 `undefined` 接口类型：
/// - 回环连接只保留目标精确命中当前系统代理端点的应用侧连接；
/// - 未定义接口只保留带明确端点的 utun 应用侧连接。
/// 外部接口流量由独立的 `-P -t external` 采集器负责。
public struct TrafficFilter: Sendable {
    public let proxyEndpoints: Set<NettopEndpoint>

    public init(proxyEndpoints: Set<NettopEndpoint> = []) {
        self.proxyEndpoints = proxyEndpoints
    }

    public func shouldKeepLoopback(_ delta: NettopDelta) -> Bool {
        guard delta.interface == "lo0",
              let remoteEndpoint = delta.remoteEndpoint,
              remoteEndpoint.isLoopback else {
            return false
        }
        return proxyEndpoints.contains(remoteEndpoint)
    }

    public func shouldKeepTunnel(_ delta: NettopDelta) -> Bool {
        guard let interface = delta.interface,
              interface.hasPrefix("utun"),
              let localEndpoint = delta.localEndpoint,
              localEndpoint.port != nil,
              let remoteEndpoint = delta.remoteEndpoint,
              remoteEndpoint.port != nil,
              !remoteEndpoint.isLoopback else {
            return false
        }
        return true
    }

    public func shouldKeepSupplemental(_ delta: NettopDelta) -> Bool {
        shouldKeepLoopback(delta) || shouldKeepTunnel(delta)
    }

    /// 兼容探针和旧调用：应丢弃表示它不属于受支持的补充连接。
    public func shouldDiscard(_ delta: NettopDelta) -> Bool {
        !shouldKeepSupplemental(delta)
    }

    /// 本地端点就是系统代理端点的回环连接属于代理进程自身（监听端）。
    /// 代理内核常以 root 运行，lsof 看不到它的监听套接字，nettop 却能看到这一侧连接，
    /// 据此识别未在静态规则里的代理进程。返回 nettop 进程令牌（`名称.pid`）。
    public static func proxyListenerProcessTokens(
        in deltas: [NettopDelta],
        proxyEndpoints: Set<NettopEndpoint>
    ) -> Set<String> {
        guard !proxyEndpoints.isEmpty else { return [] }
        var tokens: Set<String> = []
        for delta in deltas where delta.interface == "lo0" {
            guard let localEndpoint = delta.localEndpoint,
                  proxyEndpoints.contains(localEndpoint) else {
                continue
            }
            tokens.insert(delta.processName)
        }
        return tokens
    }

    public static func isLoopbackTarget(_ target: String) -> Bool {
        NettopEndpoint.parse(target)?.isLoopback == true
    }

    public static func shouldKeepAfterAttribution(
        _ delta: NettopDelta,
        category: AppCategory
    ) -> Bool {
        !(delta.interface == "utun" && category == .proxyTransport)
    }
}

public struct SupplementalTrafficReducer: Sendable {
    public init() {}

    private enum Source: Hashable {
        case loopback
        case tunnel
    }

    private struct Key: Hashable {
        let processName: String
        let source: Source
    }

    public func reduce(
        _ deltas: [NettopDelta],
        proxyEndpoints: Set<NettopEndpoint>
    ) -> [NettopDelta] {
        guard !deltas.isEmpty else { return [] }
        let filter = TrafficFilter(proxyEndpoints: proxyEndpoints)
        var order: [Key] = []
        var grouped: [Key: NettopDelta] = [:]

        for delta in deltas where filter.shouldKeepSupplemental(delta) {
            let source: Source = filter.shouldKeepLoopback(delta) ? .loopback : .tunnel
            let key = Key(processName: delta.processName, source: source)
            let normalizedInterface = source == .loopback ? "lo0" : "utun"
            if let existing = grouped[key] {
                grouped[key] = NettopDelta(
                    sampledAt: delta.sampledAt,
                    processName: delta.processName,
                    downloadBytes: saturatingAdd(existing.downloadBytes, delta.downloadBytes),
                    uploadBytes: saturatingAdd(existing.uploadBytes, delta.uploadBytes),
                    interface: normalizedInterface
                )
            } else {
                order.append(key)
                grouped[key] = NettopDelta(
                    sampledAt: delta.sampledAt,
                    processName: delta.processName,
                    downloadBytes: delta.downloadBytes,
                    uploadBytes: delta.uploadBytes,
                    interface: normalizedInterface
                )
            }
        }

        return order.compactMap { grouped[$0] }
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }
}
