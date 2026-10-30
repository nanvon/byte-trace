import Foundation

/// `/connections` 里与路径判断有关的字段。
public struct MihomoConnection: Equatable, Sendable {
    public let id: String
    /// 应用侧连接的本地端点（mihomo 的 `sourceIP:sourcePort`），与 nettop 补充通道的
    /// 本地端点一一对应：系统代理是 `127.0.0.1:随机端口`，TUN 是 `198.18.0.1:随机端口`。
    public let source: NettopEndpoint
    public let route: TrafficRoute
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(id: String, source: NettopEndpoint, route: TrafficRoute, downloadBytes: Int64, uploadBytes: Int64) {
        self.id = id
        self.source = source
        self.route = route
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public struct MihomoConnectionsSnapshot: Equatable, Sendable {
    public let downloadTotal: Int64
    public let uploadTotal: Int64
    public let connections: [MihomoConnection]

    public init(downloadTotal: Int64, uploadTotal: Int64, connections: [MihomoConnection]) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
    }
}

public enum MihomoConnectionsParser {
    private struct Payload: Decodable {
        struct Connection: Decodable {
            struct Metadata: Decodable {
                let sourceIP: String?
                let sourcePort: String?
            }

            let id: String?
            let metadata: Metadata?
            let upload: Int64?
            let download: Int64?
            let chains: [String]?
        }

        let downloadTotal: Int64?
        let uploadTotal: Int64?
        let connections: [Connection]?
    }

    public static func parse(_ data: Data) throws -> MihomoConnectionsSnapshot {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let connections = (payload.connections ?? []).compactMap { connection -> MihomoConnection? in
            guard let sourceIP = connection.metadata?.sourceIP, !sourceIP.isEmpty,
                  let sourcePort = connection.metadata?.sourcePort.flatMap(UInt16.init),
                  sourcePort > 0 else {
                return nil
            }
            return MihomoConnection(
                id: connection.id ?? "",
                source: NettopEndpoint(host: sourceIP, port: sourcePort),
                route: route(forChains: connection.chains ?? []),
                downloadBytes: max(0, connection.download ?? 0),
                uploadBytes: max(0, connection.upload ?? 0)
            )
        }
        return MihomoConnectionsSnapshot(
            downloadTotal: max(0, payload.downloadTotal ?? 0),
            uploadTotal: max(0, payload.uploadTotal ?? 0),
            connections: connections
        )
    }

    /// `chains` 从出站叶子节点排到入口策略组，第一项就是实际出口。
    public static func route(forChains chains: [String]) -> TrafficRoute {
        guard let outbound = chains.first?.trimmingCharacters(in: .whitespaces), !outbound.isEmpty else {
            return .proxied
        }
        switch outbound.uppercased() {
        case "DIRECT":
            return .proxyRuleDirect
        case "REJECT", "REJECT-DROP", "PASS":
            return .proxied
        default:
            return .proxyNode
        }
    }
}

/// 应用侧本地端点 → 出口路径的短期缓存。连接关闭后保留一段时间，覆盖 nettop
/// 帧晚于 mihomo 快照到达的情况；短于轮询间隔就结束的连接查不到，按「出口未知」记。
public final class MihomoRouteTracker: @unchecked Sendable {
    private struct Entry {
        let route: TrafficRoute
        var lastSeen: Date
    }

    private let lock = NSLock()
    private let retention: TimeInterval
    private var entries: [NettopEndpoint: Entry] = [:]
    private var lastUpdate: Date?

    public init(retention: TimeInterval = 120) {
        self.retention = retention
    }

    public func update(with snapshot: MihomoConnectionsSnapshot, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        for connection in snapshot.connections {
            entries[connection.source] = Entry(route: connection.route, lastSeen: now)
        }
        entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) <= retention }
        lastUpdate = now
    }

    public func route(forLocalEndpoint endpoint: NettopEndpoint?) -> TrafficRoute? {
        guard let endpoint else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries[endpoint]?.route
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastUpdate else { return false }
        return Date().timeIntervalSince(lastUpdate) <= retention
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll()
        lastUpdate = nil
        lock.unlock()
    }
}
