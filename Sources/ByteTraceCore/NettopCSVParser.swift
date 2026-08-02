import Foundation

public struct NettopDelta: Equatable, Sendable {
    public let sampledAt: String
    public let processName: String
    public let downloadBytes: Int64
    public let uploadBytes: Int64

    public init(
        sampledAt: String,
        processName: String,
        downloadBytes: Int64,
        uploadBytes: Int64
    ) {
        self.sampledAt = sampledAt
        self.processName = processName
        self.downloadBytes = downloadBytes
        self.uploadBytes = uploadBytes
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
    }

    private struct ParsedRow: Sendable {
        let sampledAt: String
        let processName: String
        let downloadBytes: Int64
        let uploadBytes: Int64
    }

    private var lineBuffer = Data()
    private var schema: Schema?
    private var currentRows: [ParsedRow] = []
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
        let fields = Self.parseCSVLine(line)
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
        currentRows.append(row)
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
            return []
        }

        let rows = currentRows
        currentRows.removeAll(keepingCapacity: true)
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
                    uploadBytes: row.uploadBytes
                )
            }
        }

        return [.frameCompleted(rowCount: rows.count, deltas: deltas, isBaseline: isBaseline)]
    }

    private func parseRow(_ fields: [String], using schema: Schema) -> ParsedRow? {
        let requiredIndex = max(schema.processIndex, max(schema.bytesInIndex, schema.bytesOutIndex))
        guard fields.count > requiredIndex else { return nil }

        guard let downloadBytes = Int64(fields[schema.bytesInIndex].trimmingCharacters(in: .whitespaces)),
              let uploadBytes = Int64(fields[schema.bytesOutIndex].trimmingCharacters(in: .whitespaces)),
              downloadBytes >= 0,
              uploadBytes >= 0 else {
            return nil
        }

        return ParsedRow(
            sampledAt: fields[0],
            processName: fields[schema.processIndex],
            downloadBytes: downloadBytes,
            uploadBytes: uploadBytes
        )
    }

    private static func makeSchema(from header: [String]) -> Schema? {
        guard header.first == "time",
              let bytesInIndex = header.firstIndex(of: "bytes_in"),
              let bytesOutIndex = header.firstIndex(of: "bytes_out"),
              let processIndex = processColumn(in: header) else {
            return nil
        }

        return Schema(
            columns: header,
            processIndex: processIndex,
            bytesInIndex: bytesInIndex,
            bytesOutIndex: bytesOutIndex
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

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = String()
        var isQuoted = false
        var scalarIndex = line.unicodeScalars.startIndex

        while scalarIndex < line.unicodeScalars.endIndex {
            let scalar = line.unicodeScalars[scalarIndex]

            if scalar == "\"" {
                let nextIndex = line.unicodeScalars.index(after: scalarIndex)
                if isQuoted, nextIndex < line.unicodeScalars.endIndex,
                   line.unicodeScalars[nextIndex] == "\"" {
                    field.append("\"")
                    scalarIndex = line.unicodeScalars.index(after: nextIndex)
                    continue
                }
                isQuoted.toggle()
            } else if scalar == "," && !isQuoted {
                fields.append(field)
                field.removeAll(keepingCapacity: true)
            } else {
                field.unicodeScalars.append(scalar)
            }

            scalarIndex = line.unicodeScalars.index(after: scalarIndex)
        }

        fields.append(field)
        return fields
    }
}
