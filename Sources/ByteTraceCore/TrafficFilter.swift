import Foundation

/// 回环连接只承担系统代理入口补充：外部接口流量由独立的 `-P -t external`
/// 采集器负责，因此这里仅保留目标端点精确命中当前系统代理的应用侧连接。
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

    /// 兼容探针和旧调用：应丢弃表示它不是当前系统代理的应用侧回环连接。
    public func shouldDiscard(_ delta: NettopDelta) -> Bool {
        !shouldKeepLoopback(delta)
    }

    public static func isLoopbackTarget(_ target: String) -> Bool {
        NettopEndpoint.parse(target)?.isLoopback == true
    }
}

public struct LoopbackTrafficReducer: Sendable {
    public init() {}

    public func reduce(
        _ deltas: [NettopDelta],
        proxyEndpoints: Set<NettopEndpoint>
    ) -> [NettopDelta] {
        guard !deltas.isEmpty, !proxyEndpoints.isEmpty else { return [] }
        let filter = TrafficFilter(proxyEndpoints: proxyEndpoints)
        var order: [String] = []
        var grouped: [String: NettopDelta] = [:]

        for delta in deltas where filter.shouldKeepLoopback(delta) {
            if let existing = grouped[delta.processName] {
                grouped[delta.processName] = NettopDelta(
                    sampledAt: delta.sampledAt,
                    processName: delta.processName,
                    downloadBytes: saturatingAdd(existing.downloadBytes, delta.downloadBytes),
                    uploadBytes: saturatingAdd(existing.uploadBytes, delta.uploadBytes),
                    interface: "lo0"
                )
            } else {
                order.append(delta.processName)
                grouped[delta.processName] = NettopDelta(
                    sampledAt: delta.sampledAt,
                    processName: delta.processName,
                    downloadBytes: delta.downloadBytes,
                    uploadBytes: delta.uploadBytes,
                    interface: "lo0"
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
