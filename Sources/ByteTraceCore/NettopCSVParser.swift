import Foundation

public struct NettopDelta: Equatable, Sendable {
    public let sampledAt: String
    public let processName: String
    public let downloadBytes: Int64
    public let uploadBytes: Int64
    /// 连接行所在接口（lo0/en0/utun4…）；进程行无接口信息，为 nil。
    public let interface: String?
    /// 连接行 `<->` 右侧的目标描述（仅用于内存中的过滤判断，不落库不展示）。
    public let connectionTarget: String?

    public init(
        sampledAt: String,
        processName: String,
        downloadBytes: Int64,
        uploadBytes: Int64,
        interface: String? = nil,
        connectionTarget: String? = nil
    ) {
        self.sampledAt = sampledAt
        self.processName = processName
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
        self.interface = interface
        self.connectionTarget = connectionTarget
    }
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
    }

    private struct ParsedRow: Sendable {
        let sampledAt: String
        let processName: String
        let downloadBytes: Int64
        let uploadBytes: Int64
        let interface: String?
        let connectionTarget: String?
    }

    private var lineBuffer = Data()
    private var schema: Schema?
    private var currentRows: [ParsedRow] = []
    private var currentProcessRows: [ParsedRow] = []
    private var currentProcessName: String?
    private var hasBaseline = false
    private var didFinish = false

    public private(set) var state: NettopParserState = .waitingForHeader
    public private(set) var completeFrameCount = 0
    public private(set) var malformedRowCount = 0

    public init() {}

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
        if row.interface == nil {
            guard !Self.isConnectionDescription(row.processName) else { return [] }
            currentProcessName = row.processName
            currentProcessRows.append(row)
            return []
        }
        guard let currentProcessName else { return [] }
        let attributedRow = ParsedRow(
            sampledAt: row.sampledAt,
            processName: currentProcessName,
            downloadBytes: row.downloadBytes,
            uploadBytes: row.uploadBytes,
            interface: row.interface,
            connectionTarget: row.connectionTarget
        )
        currentRows.append(attributedRow)
        return []
    }

    private mutating func beginFrame(with header: [String]) -> [NettopParserEvent] {
        var events = completeCurrentFrame()

        guard let newSchema = Self.makeSchema(from: header) else {
            schema = nil
            state = .incompatible
            let missingColumns = Self.missingColumns(in: header)
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

        // 有连接行 → 用连接行（已归属到进程）；整帧无连接行（旧 -P 风格）→ 回退用进程行。
        let sourceRows = currentRows.isEmpty ? currentProcessRows : currentRows
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
                    connectionTarget: row.connectionTarget
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

        return ParsedRow(
            sampledAt: fields[0],
            processName: fields[schema.processIndex],
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes,
            interface: interface,
            connectionTarget: interface == nil ? nil : Self.connectionTarget(in: fields[schema.processIndex])
        )
    }

    private static func byteValue(_ field: String) -> Int64? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        guard let value = Int64(trimmed), value >= 0 else { return nil }
        return value
    }

    /// 从连接行第 2 列（如 `tcp4 127.0.0.1:57123<->127.0.0.1:59169`）提取 `<->` 右侧目标。
    private static func connectionTarget(in field: String) -> String? {
        guard let range = field.range(of: "<->") else { return nil }
        let target = field[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return target.isEmpty ? nil : target
    }

    /// 第 2 列是否是连接描述（tcp4/udp4/tcp6/ipv6… 开头），用于区分进程行与连接行。
    private static func isConnectionDescription(_ field: String) -> Bool {
        let prefixes = ["tcp4", "tcp6", "udp4", "udp6", "ipv4", "ipv6", "icmp"]
        return prefixes.contains { field.hasPrefix($0) }
    }

    private static func makeSchema(from header: [String]) -> Schema? {
        guard header.first == "time",
              let bytesInIndex = header.firstIndex(of: "bytes_in"),
              let bytesOutIndex = header.firstIndex(of: "bytes_out"),
              let processIndex = processColumn(in: header) else {
            return nil
        }

        let interfaceIndex = header.firstIndex(of: "interface")

        return Schema(
            columns: header,
            processIndex: processIndex,
            bytesInIndex: bytesInIndex,
            bytesOutIndex: bytesOutIndex,
            interfaceIndex: interfaceIndex
        )
    }

    private static func missingColumns(in header: [String]) -> [String] {
        var missing: [String] = []
        if header.first != "time" { missing.append("time") }
        if !header.contains("bytes_in") { missing.append("bytes_in") }
        if !header.contains("bytes_out") { missing.append("bytes_out") }
        if processColumn(in: header) == nil { missing.append("process") }
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
