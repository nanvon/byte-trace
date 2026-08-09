import Foundation

/// 采集流量过滤规则（纯工具无关，不依赖任何代理软件/接口名/进程名）：
///
/// 连接行解析出的「目标地址」如果是本机回环（127.0.0.0/8 或 ::1），则丢弃。
/// 依据：回环目标必然是「本机进程互连」——Electron 类应用的 WebView↔本地 server
/// 假流量、以及代理软件的入站侧双计，全部表现为 127.0.0.1 目标；而真实外部流量
/// （直连或 TUN 代理）目标都是公网/局域网地址，不会落在回环段。
///
/// 隐私约定：目标地址仅在内存中做丢弃判断，不落库、不展示。
public struct TrafficFilter: Sendable {
    public init() {}

    /// 丢弃该 delta 返回 true，保留返回 false。
    public func shouldDiscard(_ delta: NettopDelta) -> Bool {
        guard let target = delta.connectionTarget else { return false }
        return TrafficFilter.isLoopbackTarget(target)
    }

    /// 判断连接目标（如 `127.0.0.1:59169`、`[::1]:443`、`::1.8021`）是否落在本机回环段。
    public static func isLoopbackTarget(_ target: String) -> Bool {
        if let ipv4 = ipv4Host(of: target) {
            return ipv4.starts(with: "127.")
        }
        return ipv6Host(of: target) == "::1"
    }

    /// 从 `host:port` 或 `host.port` 形式提取 IPv4 地址。
    private static func ipv4Host(of target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "*" else { return nil }

        // IPv4 是 `x.x.x.x:port`；端口由最后一个冒号分隔。
        let components = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else {
            return Self.tryLegacyDotPort(trimmed)
        }
        let host = String(components[0])
        guard host.contains("."), !host.contains("[") else { return nil }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return host
    }

    /// nettop 的 IPv6 连接可能写成 `::1.8021` 这种「地址.端口」形式；
    /// 若以 `::1.` 开头视为回环，否则返回 nil（不做其他 IPv6 判断）。
    private static func tryLegacyDotPort(_ target: String) -> String? {
        if target.hasPrefix("::1.") { return "::1" }
        return nil
    }

    private static func ipv6Host(of target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            // [::1]:443 形式
            let end = trimmed.firstIndex(of: "]")
            return end.map { String(trimmed[trimmed.index(after: trimmed.startIndex)..<$0]) }
        }
        if trimmed.hasPrefix("::1") {
            return "::1"
        }
        return nil
    }
}
