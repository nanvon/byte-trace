import ByteTraceCore
import Darwin
import Foundation

private struct Options {
    let duration: TimeInterval
    let runs: Int
    let numericOnly: Bool
    let process: String?

    init(arguments: [String]) {
        var duration: TimeInterval = 5
        var runs = 1
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

            case "--runs" where index + 1 < arguments.count:
                if let value = Int(arguments[index + 1]), value > 0 {
                    runs = value
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
        self.runs = runs
        self.numericOnly = numericOnly
        self.process = process
    }

    var nettopArguments: [String] {
        var result = ["-d", "-x", "-L", "0", "-s", "1"]
        if numericOnly {
            result.insert("-n", at: 0)
        }
        return result
    }
}

private typealias ByteTotals = NettopByteTotals

private struct EndpointStats {
    var connectionCount: Int64 = 0
    var bytes = ByteTotals()
}

private struct ProcessVisibility {
    let processName: String
    let reconciliation: NettopReconciliation
}

private struct ConnectionProbeReport {
    private let processFilter: String?
    var completeFrames = 0
    var baselineFrames = 0
    var malformedRows = 0
    var schemaChanges = 0
    var incompatibleSchemas = 0
    var processSummaryTotals: [String: ByteTotals] = [:]
    var connectionTotals: [String: ByteTotals] = [:]
    var endpointStats: [NettopEndpointKind: EndpointStats] = [:]

    init(processFilter: String?) {
        self.processFilter = processFilter
    }

    mutating func consume(_ event: NettopConnectionParserEvent) {
        switch event {
        case let .frameCompleted(_, processSummaries, deltas, isBaseline):
            completeFrames += 1
            if isBaseline {
                baselineFrames += 1
                return
            }

            for summary in processSummaries where matches(summary.processName) {
                var totals = processSummaryTotals[summary.processName] ?? ByteTotals()
                totals.add(
                    downloadBytes: summary.downloadBytes,
                    uploadBytes: summary.uploadBytes
                )
                processSummaryTotals[summary.processName] = totals
            }

            for delta in deltas where matches(delta.processName) {
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

    func overallReconciliation() -> NettopReconciliation {
        NettopReconciliation(
            summary: summaryByteTotals(),
            connections: connectionByteTotals()
        )
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

        let summaryTotals = summaryByteTotals()
        let allConnectionTotals = connectionByteTotals()
        let reconciliation = overallReconciliation()
        let formattedDifferencePercent = String(
            format: "%.2f",
            reconciliation.differencePercent
        )

        print(
            "[reconciliation] summary_download_bytes=\(summaryTotals.downloadBytes) "
                + "summary_upload_bytes=\(summaryTotals.uploadBytes) "
                + "connection_download_bytes=\(allConnectionTotals.downloadBytes) "
                + "connection_upload_bytes=\(allConnectionTotals.uploadBytes)"
        )
        print(
            "[reconciliation] absolute_difference_bytes=\(reconciliation.absoluteDifferenceBytes) "
                + "difference_percent=\(formattedDifferencePercent)"
        )

        let processVisibility = Set(processSummaryTotals.keys)
            .union(connectionTotals.keys)
            .map { processName -> ProcessVisibility in
                ProcessVisibility(
                    processName: processName,
                    reconciliation: NettopReconciliation(
                        summary: processSummaryTotals[processName] ?? ByteTotals(),
                        connections: connectionTotals[processName] ?? ByteTotals()
                    )
                )
            }
            .sorted { lhs, rhs in
                let lhsDifference = lhs.reconciliation.absoluteDifferenceBytes
                let rhsDifference = rhs.reconciliation.absoluteDifferenceBytes
                if lhsDifference == rhsDifference {
                    return lhs.processName < rhs.processName
                }
                return lhsDifference > rhsDifference
            }

        let statusCounts = NettopVisibilityStatus.allCases.map { status in
            let count = processVisibility.filter {
                $0.reconciliation.status == status
            }.count
            return "\(status.rawValue)=\(count)"
        }.joined(separator: ",")
        print("[visibility] status_counts=\(statusCounts)")

        for visibility in processVisibility.prefix(10)
            where visibility.reconciliation.absoluteDifferenceBytes > 0 {
            print(
                "[visibility] process=\(visibility.processName) "
                    + "status=\(visibility.reconciliation.status.rawValue) "
                    + "summary_bytes=\(visibility.reconciliation.summary.totalBytes) "
                    + "connection_bytes=\(visibility.reconciliation.connections.totalBytes) "
                    + "absolute_difference_bytes=\(visibility.reconciliation.absoluteDifferenceBytes)"
            )
        }

        print(
            "[reconciliation] status=\(reconciliation.status.rawValue) "
                + "allowed_difference_bytes=\(reconciliation.allowedDifferenceBytes)"
        )
    }

    private func summaryByteTotals() -> ByteTotals {
        processSummaryTotals.values.reduce(into: ByteTotals()) { totals, value in
            totals.add(
                downloadBytes: value.downloadBytes,
                uploadBytes: value.uploadBytes
            )
        }
    }

    private func connectionByteTotals() -> ByteTotals {
        connectionTotals.values.reduce(into: ByteTotals()) { totals, value in
            totals.add(
                downloadBytes: value.downloadBytes,
                uploadBytes: value.uploadBytes
            )
        }
    }

    private func matches(_ processName: String) -> Bool {
        guard let processFilter else { return true }
        return processName == processFilter
            || processName.hasPrefix("\(processFilter).")
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
    private var report: ConnectionProbeReport
    private var stderrData = Data()

    init(arguments: [String], processFilter: String?) {
        self.arguments = arguments
        report = ConnectionProbeReport(processFilter: processFilter)
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
    print("[collector] runs=\(options.runs)")
    if let process = options.process {
        print("[probe] process_filter=\(process) mode=in_memory")
    }
    print("[collector] storage=none ui=none")

    do {
        var statuses: [NettopVisibilityStatus] = []
        for runIndex in 1...options.runs {
            print("[run] index=\(runIndex)/\(options.runs)")
            let session = ConnectionProbeSession(
                arguments: options.nettopArguments,
                processFilter: options.process
            )
            let (report, stderr) = try session.run(duration: options.duration)
            if !stderr.isEmpty {
                print("[collector] run=\(runIndex) stderr=\(stderr)")
            }
            report.printSummary()

            guard report.completeFrames > 0 else {
                print("[result] FAIL: 第 \(runIndex) 轮未获得完整连接级 nettop CSV 帧")
                return 1
            }
            guard report.incompatibleSchemas == 0 else {
                print("[result] FAIL: 第 \(runIndex) 轮连接级 CSV 表头不兼容")
                return 1
            }
            statuses.append(report.overallReconciliation().status)
        }

        let stability = NettopVisibilityStability(statuses: statuses)
        let statusCounts = NettopVisibilityStatus.allCases.map { status in
            "\(status.rawValue)=\(stability.count(for: status))"
        }.joined(separator: ",")
        let reconciledPercent = String(
            format: "%.2f",
            stability.reconciledRate * 100
        )
        print(
            "[stability] runs=\(stability.sampleCount) status_counts=\(statusCounts) "
                + "reconciled_percent=\(reconciledPercent)"
        )
        print(
            "[result] PASS: 已完成连接级 CSV → 进程分组 → 端点分类 → 对账探针；"
                + "请以 reconciliation/visibility status 作为对账结论"
        )
        return 0
    } catch {
        print("[result] FAIL: 无法运行连接级 nettop 探针：\(error.localizedDescription)")
        return 1
    }
}

exit(runProbe(options: Options(arguments: CommandLine.arguments)))
