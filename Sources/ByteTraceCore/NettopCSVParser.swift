import Foundation

public struct NettopEndpoint: Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16?

    public init(host: String, port: UInt16?) {
        self.host = Self.canonicalHost(host)
        self.port = port
    }

    public var isLoopback: Bool {
        if host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4
            && octets.first == "127"
            && octets.allSatisfy { UInt8($0) != nil }
    }

    public static func parse(_ rawValue: String) -> NettopEndpoint? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "*", value != "*:*", value != "*.*" else {
            return nil
        }

        if value.hasPrefix("["), let closingBracket = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<closingBracket])
            let suffix = value[value.index(after: closingBracket)...]
            let port = Self.portValue(String(suffix).trimmingCharacters(in: CharacterSet(charactersIn: ":.")))
            return NettopEndpoint(host: host, port: port)
        }

        if let ipv4 = parseIPv4WithPort(value) {
            return ipv4
        }

        // nettop 的无方括号 IPv6 使用最后一个点分隔端口，例如 ::1.7890、
        // fe80::1%en0.50231；不能把最后一个冒号后的十六进制段误当端口。
        if value.contains(":"), let dot = value.lastIndex(of: ".") {
            let host = String(value[..<dot])
            let portText = String(value[value.index(after: dot)...])
            if let port = portValue(portText) {
                return NettopEndpoint(host: host, port: port)
            }
        }

        if value.contains(":") {
            return NettopEndpoint(host: value, port: nil)
        }
        return nil
    }

    private static func parseIPv4WithPort(_ value: String) -> NettopEndpoint? {
        if let colon = value.lastIndex(of: ":") {
            let host = String(value[..<colon])
            let portText = String(value[value.index(after: colon)...])
            if isIPv4(host), let port = portValue(portText) {
                return NettopEndpoint(host: host, port: port)
            }
        }

        if let dot = value.lastIndex(of: ".") {
            let host = String(value[..<dot])
            let portText = String(value[value.index(after: dot)...])
            if isIPv4(host), let port = portValue(portText) {
                return NettopEndpoint(host: host, port: port)
            }
        }
        return nil
    }

    private static func isIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { UInt8($0) != nil }
    }

    private static func portValue(_ value: String) -> UInt16? {
        guard let port = UInt16(value), port > 0 else { return nil }
        return port
    }

    private static func canonicalHost(_ rawValue: String) -> String {
        let value = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if value == "0:0:0:0:0:0:0:1" { return "::1" }
        return value
    }
}

public struct NettopDelta: Equatable, Sendable {
    public let sampledAt: String
    public let processName: String
    public let downloadBytes: Int64
    public let uploadBytes: Int64
    /// 连接行所在接口（lo0/en0/utun4…）；进程行无接口信息，为 nil。
    public let interface: String?
    /// 连接行 `<->` 右侧的目标描述（仅用于内存中的过滤判断，不落库不展示）。
    public let connectionTarget: String?
    public let localEndpoint: NettopEndpoint?
    public let remoteEndpoint: NettopEndpoint?
    public let connectionState: String?

    public init(
        sampledAt: String,
        processName: String,
        downloadBytes: Int64,
        uploadBytes: Int64,
        interface: String? = nil,
        connectionTarget: String? = nil,
        localEndpoint: NettopEndpoint? = nil,
        remoteEndpoint: NettopEndpoint? = nil,
        connectionState: String? = nil
    ) {
        self.sampledAt = sampledAt
        self.processName = processName
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.interface = interface
        self.connectionTarget = connectionTarget
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.connectionState = connectionState
    }
}

public enum NettopCSVParserMode: Equatable, Sendable {
    /// 兼容测试和旧输入；正式采集器必须显式选择下面两种模式之一。
    case automatic
    case processSummary
    case connections
}

public enum NettopParserState: Equatable, Sendable {
    case waitingForHeader
    case baseline
    case collecting
    case incompatible
}

public enum NettopParserEvent: Equatable, Sendable {
    case frameCompleted(rowCount: Int, deltas: [NettopDelta], isBaseline: Bool)
    case malformedRow
    case schemaChanged
    case incompatibleSchema(missingColumns: [String])
}

public struct NettopCSVParser: Sendable {
    private struct Schema: Equatable, Sendable {
        let columns: [String]
        let processIndex: Int
        let bytesInIndex: Int
        let bytesOutIndex: Int
        let interfaceIndex: Int?
        let stateIndex: Int?
    }

    private struct ParsedRow: Sendable {
        let sampledAt: String
        let processName: String
        let downloadBytes: Int64
        let uploadBytes: Int64
        let interface: String?
        let connectionTarget: String?
        let localEndpoint: NettopEndpoint?
        let remoteEndpoint: NettopEndpoint?
        let connectionState: String?
    }

    private var lineBuffer = Data()
    private var schema: Schema?
    private var currentRows: [ParsedRow] = []
    private var currentProcessRows: [ParsedRow] = []
    private var currentProcessName: String?
    private var hasBaseline = false
    private var didFinish = false
    private let mode: NettopCSVParserMode

    public private(set) var state: NettopParserState = .waitingForHeader
    public private(set) var completeFrameCount = 0
    public private(set) var malformedRowCount = 0

    public init(mode: NettopCSVParserMode = .automatic) {
        self.mode = mode
    }

    public mutating func consume(_ data: Data) -> [NettopParserEvent] {
        guard !didFinish, !data.isEmpty else { return [] }

        lineBuffer.append(data)
        var events: [NettopParserEvent] = []

        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let line = Data(lineBuffer[..<newlineIndex])
            lineBuffer.removeSubrange(...newlineIndex)
            events.append(contentsOf: consumeLine(line))
        }

        return events
    }

    public mutating func finish() -> [NettopParserEvent] {
        guard !didFinish else { return [] }
        didFinish = true

        var events: [NettopParserEvent] = []
        if !lineBuffer.isEmpty {
            events.append(contentsOf: consumeLine(lineBuffer))
            lineBuffer.removeAll(keepingCapacity: false)
        }
        events.append(contentsOf: completeCurrentFrame())
        return events
    }

    private mutating func consumeLine(_ data: Data) -> [NettopParserEvent] {
        var lineData = data
        if lineData.last == 0x0D {
            lineData.removeLast()
        }

        let line = String(decoding: lineData, as: UTF8.self)
        let fields = CSVLineParser.parse(line)
        guard !fields.isEmpty, !(fields.count == 1 && fields[0].isEmpty) else {
            return []
        }

        if fields.first == "time" {
            return beginFrame(with: fields)
        }

        guard let schema else { return [] }
        guard let row = parseRow(fields, using: schema) else {
            malformedRowCount += 1
            return [.malformedRow]
        }

        // 不带 -P 时输出是「进程行 → 连接行」的树形结构：
        // 进程行（interface 列为空、第 2 列为 name.pid）只用于确定归属，自身不产出流量；
        // 连接行（第 2 列以 tcp/udp/ipv/icmp 等开头）携带字节并归属到最近出现的进程行。
        // 部分连接行 interface 列为空（如 `udp4 *:*<->*:*`），同样按连接行处理但不产出流量。
        // 兜底：若整帧都没有连接行（旧 -P 风格输出），帧完成时回退用进程行产出 delta。
        let isConnection = Self.isConnectionDescription(row.processName)
        if !isConnection {
            currentProcessName = row.processName
            currentProcessRows.append(row)
            return []
        }
        guard mode != .processSummary else { return [] }
        guard mode != .connections || row.interface != nil else { return [] }
        guard let currentProcessName else { return [] }
        let attributedRow = ParsedRow(
            sampledAt: row.sampledAt,
            processName: currentProcessName,
            downloadBytes: row.downloadBytes,
            uploadBytes: row.uploadBytes,
            interface: row.interface,
            connectionTarget: row.connectionTarget,
            localEndpoint: row.localEndpoint,
            remoteEndpoint: row.remoteEndpoint,
            connectionState: row.connectionState
        )
        currentRows.append(attributedRow)
        return []
    }

    private mutating func beginFrame(with header: [String]) -> [NettopParserEvent] {
        var events = completeCurrentFrame()

        guard let newSchema = makeSchema(from: header) else {
            schema = nil
            state = .incompatible
            let missingColumns = missingColumns(in: header)
            events.append(.incompatibleSchema(missingColumns: missingColumns))
            return events
        }

        if let schema, schema != newSchema {
            events.append(.schemaChanged)
        }

        schema = newSchema
        state = hasBaseline ? .collecting : .waitingForHeader
        return events
    }

    private mutating func completeCurrentFrame() -> [NettopParserEvent] {
        guard schema != nil else {
            currentRows.removeAll(keepingCapacity: true)
            currentProcessRows.removeAll(keepingCapacity: true)
            currentProcessName = nil
            return []
        }

        let sourceRows: [ParsedRow]
        switch mode {
        case .automatic:
            sourceRows = currentRows.isEmpty ? currentProcessRows : currentRows
        case .processSummary:
            sourceRows = currentProcessRows
        case .connections:
            sourceRows = currentRows
        }
        let rows = sourceRows
        currentRows.removeAll(keepingCapacity: true)
        currentProcessRows.removeAll(keepingCapacity: true)
        currentProcessName = nil
        completeFrameCount += 1

        let isBaseline = !hasBaseline
        hasBaseline = true
        state = isBaseline ? .baseline : .collecting

        let deltas: [NettopDelta]
        if isBaseline {
            deltas = []
        } else {
            deltas = rows.compactMap { row in
                guard row.downloadBytes > 0 || row.uploadBytes > 0 else { return nil }
                return NettopDelta(
                    sampledAt: row.sampledAt,
                    processName: row.processName,
                    downloadBytes: row.downloadBytes,
                    uploadBytes: row.uploadBytes,
                    interface: row.interface,
                    connectionTarget: row.connectionTarget,
                    localEndpoint: row.localEndpoint,
                    remoteEndpoint: row.remoteEndpoint,
                    connectionState: row.connectionState
                )
            }
        }

        return [.frameCompleted(rowCount: rows.count, deltas: deltas, isBaseline: isBaseline)]
    }

    private func parseRow(_ fields: [String], using schema: Schema) -> ParsedRow? {
        let requiredIndex = max(schema.processIndex, max(schema.bytesInIndex, schema.bytesOutIndex))
        guard fields.count > requiredIndex else { return nil }

        // 监听/未连接的行 bytes 列为空，按 0 处理；非数字或负数视为非法。
        guard let downloadBytes = Self.byteValue(fields[schema.bytesInIndex]),
              let uploadBytes = Self.byteValue(fields[schema.bytesOutIndex]) else {
            return nil
        }

        var interface: String?
        if let interfaceIndex = schema.interfaceIndex, fields.indices.contains(interfaceIndex) {
            let value = fields[interfaceIndex].trimmingCharacters(in: .whitespaces)
            interface = value.isEmpty ? nil : value
        }

        var connectionState: String?
        if let stateIndex = schema.stateIndex, fields.indices.contains(stateIndex) {
            let value = fields[stateIndex].trimmingCharacters(in: .whitespaces)
            connectionState = value.isEmpty ? nil : value
        }

        let endpoints = Self.connectionEndpoints(in: fields[schema.processIndex])

        return ParsedRow(
            sampledAt: fields[0],
            processName: fields[schema.processIndex],
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes,
            interface: interface,
            connectionTarget: endpoints?.target,
            localEndpoint: endpoints.flatMap { NettopEndpoint.parse($0.source) },
            remoteEndpoint: endpoints.flatMap { NettopEndpoint.parse($0.target) },
            connectionState: connectionState
        )
    }

    private static func byteValue(_ field: String) -> Int64? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        guard let value = Int64(trimmed), value >= 0 else { return nil }
        return value
    }

    /// 从连接行第 2 列（如 `tcp4 127.0.0.1:57123<->127.0.0.1:59169`）提取 `<->` 右侧目标。
    private static func connectionEndpoints(in field: String) -> (source: String, target: String)? {
        guard let range = field.range(of: "<->") else { return nil }
        guard let space = field.firstIndex(of: " ") else { return nil }
        let source = field[field.index(after: space)..<range.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        let target = field[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty, !target.isEmpty else { return nil }
        return (source, target)
    }

    /// 第 2 列是否是连接描述（tcp4/udp4/tcp6/ipv6… 开头），用于区分进程行与连接行。
    private static func isConnectionDescription(_ field: String) -> Bool {
        let prefixes = ["tcp4", "tcp6", "udp4", "udp6", "ipv4", "ipv6", "icmp"]
        return prefixes.contains { field.hasPrefix($0) }
    }

    private func makeSchema(from header: [String]) -> Schema? {
        guard header.first == "time",
              let bytesInIndex = header.firstIndex(of: "bytes_in"),
              let bytesOutIndex = header.firstIndex(of: "bytes_out"),
              let processIndex = Self.processColumn(in: header) else {
            return nil
        }

        let interfaceIndex = header.firstIndex(of: "interface")
        if mode == .connections, interfaceIndex == nil { return nil }

        return Schema(
            columns: header,
            processIndex: processIndex,
            bytesInIndex: bytesInIndex,
            bytesOutIndex: bytesOutIndex,
            interfaceIndex: interfaceIndex,
            stateIndex: header.firstIndex(of: "state")
        )
    }

    private func missingColumns(in header: [String]) -> [String] {
        var missing: [String] = []
        if header.first != "time" { missing.append("time") }
        if !header.contains("bytes_in") { missing.append("bytes_in") }
        if !header.contains("bytes_out") { missing.append("bytes_out") }
        if Self.processColumn(in: header) == nil { missing.append("process") }
        if mode == .connections, !header.contains("interface") { missing.append("interface") }
        return missing
    }

    private static func processColumn(in header: [String]) -> Int? {
        if header.indices.contains(1), header[1].isEmpty {
            return 1
        }

        let knownNames = ["process", "process_name", "name"]
        return header.firstIndex { knownNames.contains($0) }
    }

}
