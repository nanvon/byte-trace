import Foundation

public struct NettopConnectionDelta: Equatable, Sendable {
    public let sampledAt: String
    public let processName: String
    public let socket: String
    public let remoteEndpoint: String?
    public let interfaceName: String?
    public let state: String?
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(
        sampledAt: String,
        processName: String,
        socket: String,
        remoteEndpoint: String?,
        interfaceName: String?,
        state: String?,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) {
        self.sampledAt = sampledAt
        self.processName = processName
        self.socket = socket
        self.remoteEndpoint = remoteEndpoint
        self.interfaceName = interfaceName
        self.state = state
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public struct NettopProcessSummary: Equatable, Sendable {
    public let processName: String
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(
        processName: String,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) {
        self.processName = processName
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
    }
}

public enum NettopConnectionParserState: Equatable, Sendable {
    case waitingForHeader
    case baseline
    case collecting
    case incompatible
}

public enum NettopConnectionParserEvent: Equatable, Sendable {
    case frameCompleted(
        rowCount: Int,
        processSummaries: [NettopProcessSummary],
        deltas: [NettopConnectionDelta],
        isBaseline: Bool
    )
    case malformedRow
    case schemaChanged
    case incompatibleSchema(missingColumns: [String])
}

public struct NettopConnectionCSVParser: Sendable {
    private struct Schema: Equatable, Sendable {
        let columns: [String]
        let connectionIndex: Int
        let interfaceIndex: Int
        let stateIndex: Int
        let bytesInIndex: Int
        let bytesOutIndex: Int
    }

    private struct ParsedRow: Sendable {
        let sampledAt: String
        let processName: String
        let socket: String
        let remoteEndpoint: String?
        let interfaceName: String?
        let state: String?
        let downloadBytes: Int64
        let uploadBytes: Int64
    }

    private enum ParsedLine: Sendable {
        case process(summary: NettopProcessSummary)
        case connection(ParsedRow)
    }

    private var lineBuffer = Data()
    private var schema: Schema?
    private var currentRows: [ParsedRow] = []
    private var currentProcessSummaries: [NettopProcessSummary] = []
    private var currentProcessName: String?
    private var hasBaseline = false
    private var didFinish = false

    public private(set) var state: NettopConnectionParserState = .waitingForHeader
    public private(set) var completeFrameCount = 0
    public private(set) var malformedRowCount = 0

    public init() {}

    public mutating func consume(_ data: Data) -> [NettopConnectionParserEvent] {
        guard !didFinish, !data.isEmpty else { return [] }

        lineBuffer.append(data)
        var events: [NettopConnectionParserEvent] = []

        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let line = Data(lineBuffer[..<newlineIndex])
            lineBuffer.removeSubrange(...newlineIndex)
            events.append(contentsOf: consumeLine(line))
        }

        return events
    }

    public mutating func finish() -> [NettopConnectionParserEvent] {
        guard !didFinish else { return [] }
        didFinish = true

        var events: [NettopConnectionParserEvent] = []
        if !lineBuffer.isEmpty {
            events.append(contentsOf: consumeLine(lineBuffer))
            lineBuffer.removeAll(keepingCapacity: false)
        }
        events.append(contentsOf: completeCurrentFrame())
        return events
    }

    private mutating func consumeLine(_ data: Data) -> [NettopConnectionParserEvent] {
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
        guard let parsedLine = parseLine(fields, using: schema) else {
            malformedRowCount += 1
            return [.malformedRow]
        }

        switch parsedLine {
        case let .process(summary):
            currentProcessName = summary.processName
            currentProcessSummaries.append(summary)
        case let .connection(row):
            currentRows.append(row)
        }
        return []
    }

    private mutating func beginFrame(with header: [String]) -> [NettopConnectionParserEvent] {
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

    private mutating func completeCurrentFrame() -> [NettopConnectionParserEvent] {
        guard schema != nil else {
            currentRows.removeAll(keepingCapacity: true)
            currentProcessSummaries.removeAll(keepingCapacity: true)
            currentProcessName = nil
            return []
        }

        let rows = currentRows
        let processSummaries = currentProcessSummaries
        currentRows.removeAll(keepingCapacity: true)
        currentProcessSummaries.removeAll(keepingCapacity: true)
        currentProcessName = nil
        completeFrameCount += 1

        let isBaseline = !hasBaseline
        hasBaseline = true
        state = isBaseline ? .baseline : .collecting

        let deltas: [NettopConnectionDelta]
        if isBaseline {
            deltas = []
        } else {
            deltas = rows.compactMap { row in
                guard row.downloadBytes > 0 || row.uploadBytes > 0 else { return nil }
                return NettopConnectionDelta(
                    sampledAt: row.sampledAt,
                    processName: row.processName,
                    socket: row.socket,
                    remoteEndpoint: row.remoteEndpoint,
                    interfaceName: row.interfaceName,
                    state: row.state,
                    downloadBytes: row.downloadBytes,
                    uploadBytes: row.uploadBytes
                )
            }
        }

        return [
            .frameCompleted(
                rowCount: rows.count,
                processSummaries: processSummaries,
                deltas: deltas,
                isBaseline: isBaseline
            )
        ]
    }

    private func parseLine(
        _ fields: [String],
        using schema: Schema
    ) -> ParsedLine? {
        let requiredIndex = max(
            schema.connectionIndex,
            max(
                schema.interfaceIndex,
                max(schema.stateIndex, max(schema.bytesInIndex, schema.bytesOutIndex))
            )
        )
        guard fields.count > requiredIndex else { return nil }

        let connection = fields[schema.connectionIndex].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !connection.isEmpty else { return nil }

        if connection.contains("<->") {
            guard let processName = currentProcessName else { return nil }
            guard let downloadBytes = Self.parseCounter(
                fields[schema.bytesInIndex],
                emptyValueIsZero: true
            ), let uploadBytes = Self.parseCounter(
                fields[schema.bytesOutIndex],
                emptyValueIsZero: true
            ) else {
                return nil
            }

            return .connection(
                ParsedRow(
                    sampledAt: fields[0],
                    processName: processName,
                    socket: connection,
                    remoteEndpoint: Self.remoteEndpoint(from: connection),
                    interfaceName: Self.optionalValue(fields[schema.interfaceIndex]),
                    state: Self.optionalValue(fields[schema.stateIndex]),
                    downloadBytes: downloadBytes,
                    uploadBytes: uploadBytes
                )
            )
        }

        guard fields[schema.interfaceIndex].isEmpty,
              fields[schema.stateIndex].isEmpty,
              let downloadBytes = Self.parseCounter(
                  fields[schema.bytesInIndex],
                  emptyValueIsZero: false
              ), let uploadBytes = Self.parseCounter(
                  fields[schema.bytesOutIndex],
                  emptyValueIsZero: false
              ) else {
            return nil
        }
        return .process(
            summary: NettopProcessSummary(
                processName: connection,
                downloadBytes: downloadBytes,
                uploadBytes: uploadBytes
            )
        )
    }

    private static func makeSchema(from header: [String]) -> Schema? {
        guard header.first == "time",
              header.indices.contains(1),
              let interfaceIndex = header.firstIndex(of: "interface"),
              let stateIndex = header.firstIndex(of: "state"),
              let bytesInIndex = header.firstIndex(of: "bytes_in"),
              let bytesOutIndex = header.firstIndex(of: "bytes_out") else {
            return nil
        }

        return Schema(
            columns: header,
            connectionIndex: 1,
            interfaceIndex: interfaceIndex,
            stateIndex: stateIndex,
            bytesInIndex: bytesInIndex,
            bytesOutIndex: bytesOutIndex
        )
    }

    private static func missingColumns(in header: [String]) -> [String] {
        var missing: [String] = []
        if header.first != "time" { missing.append("time") }
        if !header.indices.contains(1) { missing.append("process_or_connection") }
        if !header.contains("interface") { missing.append("interface") }
        if !header.contains("state") { missing.append("state") }
        if !header.contains("bytes_in") { missing.append("bytes_in") }
        if !header.contains("bytes_out") { missing.append("bytes_out") }
        return missing
    }

    private static func optionalValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseCounter(
        _ value: String,
        emptyValueIsZero: Bool
    ) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, emptyValueIsZero { return 0 }
        guard let number = Int64(trimmed), number >= 0 else { return nil }
        return number
    }

    private static func remoteEndpoint(from socket: String) -> String? {
        guard let separator = socket.range(of: "<->") else { return nil }
        let endpoint = socket[separator.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return endpoint.isEmpty ? nil : endpoint
    }
}
