import ByteTraceCore
import Darwin
import Foundation

private struct Options {
    let duration: TimeInterval
    let numericOnly: Bool
    let process: String?

    init(arguments: [String]) {
        var duration: TimeInterval = 5
        var numericOnly = false
        var process: String?
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--duration" where index + 1 < arguments.count:
                if let value = TimeInterval(arguments[index + 1]), value > 0 {
                    duration = value
                }
                index += 2

            case "--numeric":
                numericOnly = true
                index += 1

            case "--process" where index + 1 < arguments.count:
                process = arguments[index + 1]
                index += 2

            default:
                index += 1
            }
        }

        self.duration = duration
        self.numericOnly = numericOnly
        self.process = process
    }

    var nettopArguments: [String] {
        var result = ["-d", "-x", "-L", "0", "-s", "1"]
        if numericOnly {
            result.insert("-n", at: 0)
        }
        if let process {
            result.append(contentsOf: ["-p", process])
        }
        return result
    }
}

private struct ByteTotals {
    var downloadBytes: Int64 = 0
    var uploadBytes: Int64 = 0

    var totalBytes: Int64 {
        Self.saturatingAdd(downloadBytes, uploadBytes)
    }

    mutating func add(downloadBytes: Int64, uploadBytes: Int64) {
        self.downloadBytes = Self.saturatingAdd(self.downloadBytes, downloadBytes)
        self.uploadBytes = Self.saturatingAdd(self.uploadBytes, uploadBytes)
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

private struct EndpointStats {
    var connectionCount: Int64 = 0
    var bytes = ByteTotals()
}

private struct ProcessMismatch {
    let processName: String
    let summary: ByteTotals
    let connections: ByteTotals

    var difference: Int64 {
        absDifference(summary.totalBytes, connections.totalBytes)
    }

    private func absDifference(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}

private struct ConnectionProbeReport {
    var completeFrames = 0
    var baselineFrames = 0
    var malformedRows = 0
    var schemaChanges = 0
    var incompatibleSchemas = 0
    var processSummaryTotals: [String: ByteTotals] = [:]
    var connectionTotals: [String: ByteTotals] = [:]
    var endpointStats: [NettopEndpointKind: EndpointStats] = [:]

    mutating func consume(_ event: NettopConnectionParserEvent) {
        switch event {
        case let .frameCompleted(_, processSummaries, deltas, isBaseline):
            completeFrames += 1
            if isBaseline {
                baselineFrames += 1
                return
            }

            for summary in processSummaries {
                var totals = processSummaryTotals[summary.processName] ?? ByteTotals()
                totals.add(
                    downloadBytes: summary.downloadBytes,
                    uploadBytes: summary.uploadBytes
                )
                processSummaryTotals[summary.processName] = totals
            }

            for delta in deltas {
                var processTotals = connectionTotals[delta.processName] ?? ByteTotals()
                processTotals.add(
                    downloadBytes: delta.downloadBytes,
                    uploadBytes: delta.uploadBytes
                )
                connectionTotals[delta.processName] = processTotals

                let kind = NettopEndpointClassifier.classify(delta.remoteEndpoint)
                var stats = endpointStats[kind] ?? EndpointStats()
                stats.connectionCount += 1
                stats.bytes.add(
                    downloadBytes: delta.downloadBytes,
                    uploadBytes: delta.uploadBytes
                )
                endpointStats[kind] = stats
            }

        case .malformedRow:
            malformedRows += 1
        case .schemaChanged:
            schemaChanges += 1
        case .incompatibleSchema:
            incompatibleSchemas += 1
        }
    }

    func printSummary() {
        print("[probe] complete_frames=\(completeFrames)")
        print("[probe] baseline_frames=\(baselineFrames)")
        print("[probe] malformed_rows=\(malformedRows)")
        print("[probe] schema_changes=\(schemaChanges)")
        print("[probe] incompatible_schemas=\(incompatibleSchemas)")

        for kind in NettopEndpointKind.allCases {
            let stats = endpointStats[kind] ?? EndpointStats()
            print(
                "[endpoint] kind=\(kind.rawValue) connections=\(stats.connectionCount) "
                    + "download_bytes=\(stats.bytes.downloadBytes) "
                    + "upload_bytes=\(stats.bytes.uploadBytes) "
                    + "total_bytes=\(stats.bytes.totalBytes)"
            )
        }

        let summaryTotals = processSummaryTotals.values.reduce(into: ByteTotals()) { totals, value in
            totals.add(
                downloadBytes: value.downloadBytes,
                uploadBytes: value.uploadBytes
            )
        }
        let allConnectionTotals = connectionTotals.values.reduce(into: ByteTotals()) { totals, value in
            totals.add(
                downloadBytes: value.downloadBytes,
                uploadBytes: value.uploadBytes
            )
        }
        let difference = absoluteDifference(summaryTotals.totalBytes, allConnectionTotals.totalBytes)
        let differencePercent = summaryTotals.totalBytes == 0
            ? 0
            : Double(difference) / Double(summaryTotals.totalBytes) * 100
        let formattedDifferencePercent = String(format: "%.2f", differencePercent)

        print(
            "[reconciliation] summary_download_bytes=\(summaryTotals.downloadBytes) "
                + "summary_upload_bytes=\(summaryTotals.uploadBytes) "
                + "connection_download_bytes=\(allConnectionTotals.downloadBytes) "
                + "connection_upload_bytes=\(allConnectionTotals.uploadBytes)"
        )
        print(
            "[reconciliation] absolute_difference_bytes=\(difference) "
                + "difference_percent=\(formattedDifferencePercent)"
        )

        let mismatches = Set(processSummaryTotals.keys)
            .union(connectionTotals.keys)
            .map { processName in
                ProcessMismatch(
                    processName: processName,
                    summary: processSummaryTotals[processName] ?? ByteTotals(),
                    connections: connectionTotals[processName] ?? ByteTotals()
                )
            }
            .filter { $0.difference > 0 }
            .sorted { $0.difference > $1.difference }

        for mismatch in mismatches.prefix(10) {
            print(
                "[mismatch] process=\(mismatch.processName) "
                    + "summary_bytes=\(mismatch.summary.totalBytes) "
                    + "connection_bytes=\(mismatch.connections.totalBytes) "
                    + "absolute_difference_bytes=\(mismatch.difference)"
            )
        }

        let threshold = max(1024, Int64(Double(summaryTotals.totalBytes) * 0.05))
        let status = difference <= threshold ? "PASS" : "WARN"
        print(
            "[reconciliation] status=\(status) allowed_difference_bytes=\(threshold)"
        )
    }

    private func absoluteDifference(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}

private final class ConnectionProbeSession: @unchecked Sendable {
    private let arguments: [String]
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let parserQueue = DispatchQueue(
        label: "com.nanvon.ByteTrace.connection-probe-parser"
    )
    private let readGroup = DispatchGroup()
    private let stderrLock = NSLock()
    private var parser = NettopConnectionCSVParser()
    private var report = ConnectionProbeReport()
    private var stderrData = Data()

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func run(duration: TimeInterval) throws -> (ConnectionProbeReport, String) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let nullInput = FileHandle(forReadingAtPath: "/dev/null") {
            process.standardInput = nullInput
        }

        try process.run()
        startReaders()
        let deadline = Date().addingTimeInterval(duration)
        RunLoop.main.run(until: deadline)
        stop()

        let message = stderrLock.withLock {
            String(decoding: stderrData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let finalReport = parserQueue.sync { report }
        return (finalReport, message)
    }

    private func startReaders() {
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer { self.readGroup.leave() }
            self.readUntilEOF(stdoutPipe.fileHandleForReading) { data in
                self.parserQueue.sync {
                    let events = self.parser.consume(data)
                    for event in events {
                        self.report.consume(event)
                    }
                }
            }
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            defer { self.readGroup.leave() }
            self.readUntilEOF(stderrPipe.fileHandleForReading) { data in
                self.stderrLock.lock()
                self.stderrData.append(data)
                self.stderrLock.unlock()
            }
        }
    }

    private func stop() {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        readGroup.wait()
        parserQueue.sync {
            for event in parser.finish() {
                report.consume(event)
            }
        }
    }

    private func readUntilEOF(
        _ handle: FileHandle,
        onData: (Data) -> Void
    ) {
        while true {
            do {
                guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else {
                    return
                }
                onData(data)
            } catch {
                return
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private func runProbe(options: Options) -> Int32 {
    print("ByteTrace 连接级 nettop 只读探针")
    print("[collector] executable=/usr/bin/nettop")
    print("[collector] arguments=\(options.nettopArguments.joined(separator: " "))")
    print("[collector] duration_seconds=\(options.duration)")
    print("[collector] storage=none ui=none")

    do {
        let session = ConnectionProbeSession(arguments: options.nettopArguments)
        let (report, stderr) = try session.run(duration: options.duration)
        if !stderr.isEmpty {
            print("[collector] stderr=\(stderr)")
        }
        report.printSummary()

        guard report.completeFrames > 0 else {
            print("[result] FAIL: 未获得完整连接级 nettop CSV 帧")
            return 1
        }
        guard report.incompatibleSchemas == 0 else {
            print("[result] FAIL: 连接级 CSV 表头不兼容")
            return 1
        }
        print("[result] PASS: 已完成连接级 CSV → 进程分组 → 端点分类 → 对账探针")
        return 0
    } catch {
        print("[result] FAIL: 无法运行连接级 nettop 探针：\(error.localizedDescription)")
        return 1
    }
}

exit(runProbe(options: Options(arguments: CommandLine.arguments)))
