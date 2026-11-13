import Foundation

/// `/connections` 里与路径判断有关的字段。
public struct MihomoConnection: Equatable, Sendable {
    public let id: String
    /// 应用侧连接的本地端点（mihomo 的 `sourceIP:sourcePort`），与 nettop 补充通道的
    /// 本地端点一一对应：系统代理是 `127.0.0.1:随机端口`，TUN 是 `198.18.0.1:随机端口`。
    public let source: NettopEndpoint
    public let route: TrafficRoute
    public let exitName: String?
    public let domain: String?
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(
        id: String, source: NettopEndpoint, route: TrafficRoute, downloadBytes: Int64, uploadBytes: Int64,
        exitName: String? = nil, domain: String? = nil
    ) {
        self.id = id
        self.source = source
        self.route = route
        self.exitName = exitName
        self.domain = domain
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
    private static let includeDomainsKey = CodingUserInfoKey(rawValue: "includeMihomoDomains")!

    private struct Payload: Decodable {
        struct Connection: Decodable {
            struct Metadata: Decodable {
                let sourceIP: String?
                let sourcePort: String?
                let host: String?
                let sniffHost: String?

                private enum CodingKeys: String, CodingKey {
                    case sourceIP, sourcePort, host, sniffHost
                }

                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    sourceIP = try values.decodeIfPresent(String.self, forKey: .sourceIP)
                    sourcePort = try values.decodeIfPresent(String.self, forKey: .sourcePort)
                    if decoder.userInfo[MihomoConnectionsParser.includeDomainsKey] as? Bool == true {
                        host = try? values.decodeIfPresent(String.self, forKey: .host)
                        sniffHost = try? values.decodeIfPresent(String.self, forKey: .sniffHost)
                    } else {
                        host = nil
                        sniffHost = nil
                    }
                }
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

    public static func parse(_ data: Data, includeDomains: Bool = false) throws -> MihomoConnectionsSnapshot {
        let decoder = JSONDecoder()
        if includeDomains { decoder.userInfo[includeDomainsKey] = true }
        let payload = try decoder.decode(Payload.self, from: data)
        let connections = (payload.connections ?? []).compactMap { connection -> MihomoConnection? in
            guard let sourceIP = connection.metadata?.sourceIP, !sourceIP.isEmpty,
                  let sourcePort = connection.metadata?.sourcePort.flatMap(UInt16.init),
                  sourcePort > 0 else {
                return nil
            }
            let resolution = RouteResolution(
                route: route(forChains: connection.chains ?? []),
                exitName: connection.chains?.first,
                domain: connection.metadata?.host.flatMap(DomainName.registrable)
                    ?? connection.metadata?.sniffHost.flatMap(DomainName.registrable)
            )
            return MihomoConnection(
                id: connection.id ?? "",
                source: NettopEndpoint(host: sourceIP, port: sourcePort),
                route: resolution.route,
                downloadBytes: max(0, connection.download ?? 0),
                uploadBytes: max(0, connection.upload ?? 0),
                exitName: resolution.exitName,
                domain: resolution.domain
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
        let resolution: RouteResolution
        let lastSeen: Date
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
        var snapshotRoutes: [NettopEndpoint: RouteResolution] = [:]
        for connection in snapshot.connections {
            let resolution = RouteResolution(
                route: connection.route, exitName: connection.exitName, domain: connection.domain
            )
            if let existing = snapshotRoutes[connection.source] {
                snapshotRoutes[connection.source] = existing.route == resolution.route
                    ? RouteResolution(
                        route: existing.route,
                        exitName: existing.exitName == resolution.exitName ? existing.exitName : nil,
                        domain: existing.domain == resolution.domain ? existing.domain : nil
                    )
                    : .proxied
            } else {
                snapshotRoutes[connection.source] = resolution
            }
        }
        for (endpoint, resolution) in snapshotRoutes {
            entries[endpoint] = Entry(resolution: resolution, lastSeen: now)
        }
        entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) <= retention }
        lastUpdate = now
    }

    public func route(forLocalEndpoint endpoint: NettopEndpoint?, at now: Date = Date()) -> TrafficRoute? {
        resolution(forLocalEndpoint: endpoint, at: now)?.route
    }

    public func resolution(forLocalEndpoint endpoint: NettopEndpoint?, at now: Date = Date()) -> RouteResolution? {
        guard let endpoint else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[endpoint], now.timeIntervalSince(entry.lastSeen) <= retention else {
            return nil
        }
        return entry.resolution
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
