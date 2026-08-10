import Foundation

public struct MihomoConnectionSnapshot: Decodable, Equatable, Sendable {
    public let connections: [MihomoConnection]

    public init(connections: [MihomoConnection]) {
        self.connections = connections
    }
}

public struct MihomoConnection: Decodable, Equatable, Sendable {
    public struct Metadata: Decodable, Equatable, Sendable {
        public let host: String?
        public let processPath: String?

        public init(host: String? = nil, processPath: String? = nil) {
            self.host = host
            self.processPath = processPath
        }
    }

    public let id: String
    public let metadata: Metadata
    public let uploadBytes: Int64?
    public let downloadBytes: Int64?

    private enum CodingKeys: String, CodingKey {
        case id
        case metadata
        case uploadBytes = "upload"
        case downloadBytes = "download"
    }

    public init(
        id: String,
        metadata: Metadata,
        uploadBytes: Int64?,
        downloadBytes: Int64?
    ) {
        self.id = id
        self.metadata = metadata
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        metadata = (try? container.decode(Metadata.self, forKey: .metadata))
            ?? Metadata()
        uploadBytes = try? container.decode(Int64.self, forKey: .uploadBytes)
        downloadBytes = try? container.decode(Int64.self, forKey: .downloadBytes)
    }
}

public struct MihomoConnectionDelta: Equatable, Sendable {
    public let sampledAt: Date
    public let host: String?
    public let processPath: String?
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(
        sampledAt: Date,
        host: String?,
        processPath: String?,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) {
        self.sampledAt = sampledAt
        self.host = host
        self.processPath = processPath
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public final class MihomoConnectionAccumulator: @unchecked Sendable {
    private struct Counter {
        let uploadBytes: Int64
        let downloadBytes: Int64
    }

    private let lock = NSLock()
    private let maxTrackedConnections: Int
    private var previous: [String: Counter] = [:]
    private var hasBaseline = false

    public init(maxTrackedConnections: Int = 100_000) {
        self.maxTrackedConnections = max(1, maxTrackedConnections)
    }

    public var trackedConnectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return previous.count
    }

    public func reset() {
        lock.lock()
        previous.removeAll(keepingCapacity: true)
        hasBaseline = false
        lock.unlock()
    }

    public func consume(
        _ snapshot: MihomoConnectionSnapshot,
        sampledAt: Date = Date()
    ) -> [MihomoConnectionDelta] {
        lock.lock()
        defer { lock.unlock() }

        var current: [String: Counter] = [:]
        current.reserveCapacity(min(snapshot.connections.count, maxTrackedConnections))
        var validConnections: [MihomoConnection] = []
        validConnections.reserveCapacity(min(snapshot.connections.count, maxTrackedConnections))

        for connection in snapshot.connections {
            guard current.count < maxTrackedConnections,
                  !connection.id.isEmpty,
                  current[connection.id] == nil else {
                continue
            }
            guard let uploadBytes = connection.uploadBytes,
                  let downloadBytes = connection.downloadBytes,
                  uploadBytes >= 0,
                  downloadBytes >= 0 else {
                // 单帧字段畸形不应让一个仍活动的连接“消失”；保留旧基线，
                // 避免下一帧恢复正常后把全部累计值再次当作新连接流量。
                if hasBaseline, let old = previous[connection.id] {
                    current[connection.id] = old
                }
                continue
            }
            current[connection.id] = Counter(
                uploadBytes: uploadBytes,
                downloadBytes: downloadBytes
            )
            validConnections.append(connection)
        }

        guard hasBaseline else {
            previous = current
            hasBaseline = true
            return []
        }

        var deltas: [MihomoConnectionDelta] = []
        deltas.reserveCapacity(validConnections.count)
        for connection in validConnections {
            guard let counter = current[connection.id] else { continue }

            let uploadDelta: Int64
            let downloadDelta: Int64
            if let old = previous[connection.id] {
                guard counter.uploadBytes >= old.uploadBytes,
                      counter.downloadBytes >= old.downloadBytes else {
                    continue
                }
                uploadDelta = counter.uploadBytes - old.uploadBytes
                downloadDelta = counter.downloadBytes - old.downloadBytes
            } else {
                // 首帧之后新出现的连接可能已传输少量数据；其当前累计值就是目前
                // 唯一可观察到的增量。极短连接若从未出现在快照中仍然无法补回。
                uploadDelta = counter.uploadBytes
                downloadDelta = counter.downloadBytes
            }

            guard uploadDelta > 0 || downloadDelta > 0 else { continue }
            deltas.append(
                MihomoConnectionDelta(
                    sampledAt: sampledAt,
                    host: connection.metadata.host,
                    processPath: connection.metadata.processPath,
                    downloadBytes: downloadDelta,
                    uploadBytes: uploadDelta
                )
            )
        }

        // 仅保留当前活动连接，已消失连接不会形成无界缓存。
        previous = current
        return deltas
    }
}
