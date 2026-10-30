import ByteTraceCore
import Darwin
import Foundation

private struct Options {
    let duration: TimeInterval
    /// `--accuracy [URL]`：用 curl 分别直连和经系统代理下载已知大小的内容，
    /// 对照 curl 自报的字节数检查两个通道的计数。
    let accuracyURL: String?
    /// `--restart-check [URL]`：两个外部通道同时采集，一个中途重启并做间隙补偿，对照另一个不中断的通道。
    let restartCheckURL: String?
    /// `--routes`：在 `--accuracy` 基础上轮询 mihomo 连接表，再加一次经代理命中规则直连的下载，
    /// 核对每个用例的字节被分到哪条出口路径。
    let checksRoutes: Bool

    static let defaultAccuracyURL = "https://speed.cloudflare.com/__down?bytes=20000000"
    /// 国内 CDN 上的大文件，常见分流规则（`cn_domain` / `GEOSITE,cn`）会走 DIRECT；只取前 20 MB。
    static let ruleDirectURL = "https://dldir1.qq.com/weixin/Universal/Mac/WeChatMac.dmg"

    init(arguments: [String]) {
        var duration: TimeInterval = 15
        var accuracyURL: String?
        var restartCheckURL: String?
        var checksRoutes = false
        var index = 1

        while index < arguments.count {
            if arguments[index] == "--duration", index + 1 < arguments.count,
               let value = TimeInterval(arguments[index + 1]), value > 0 {
                duration = value
                index += 2
            } else if arguments[index] == "--accuracy" {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    accuracyURL = arguments[index + 1]
                    index += 2
                } else {
                    accuracyURL = Self.defaultAccuracyURL
                    index += 1
                }
            } else if arguments[index] == "--routes" {
                checksRoutes = true
                index += 1
            } else if arguments[index] == "--restart-check" {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    restartCheckURL = arguments[index + 1]
                    index += 2
                } else {
                    restartCheckURL = Self.defaultAccuracyURL
                    index += 1
                }
            } else {
                index += 1
            }
        }

        self.duration = duration
        self.accuracyURL = accuracyURL ?? (checksRoutes ? Self.defaultAccuracyURL : nil)
        self.restartCheckURL = restartCheckURL
        self.checksRoutes = checksRoutes
    }
}

private struct ProcessTraffic {
    var download: Int64 = 0
    var upload: Int64 = 0
}

private struct CurlResult {
    let label: String
    let pid: Int32
    let downloadBytes: Int64
    let uploadBytes: Int64
    let status: Int32
}

private enum ProbeLane: String {
    case external
    case supplemental
}

private struct ProbeSummary {
    let completeFrames: Int
    let baselineFrames: Int
    let nonzeroSamples: Int
    let malformedRows: Int
    let schemaChanges: Int
    let incompatibleSchemas: Int
    let attributedApps: Int
    let proxySamples: Int
    let storageErrors: Int
    let externalFrames: Int
    let supplementalFrames: Int
    let externalSamples: Int
    let supplementalSamples: Int
}

private struct ProbeSample {
    let lane: ProbeLane
    let delta: NettopDelta
    let route: TrafficRoute
    let attributed: AttributedProcess
}

private final class ProbeCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var completeFrames = 0
    private var baselineFrames = 0
    private var nonzeroSamples = 0
    private var malformedRows = 0
    private var schemaChanges = 0
    private var incompatibleSchemas = 0
    private var attributedAppKeys: Set<String> = []
    private var proxySamples = 0
    private var storageErrors = 0
    private var printedSamples = 0
    private var externalFrames = 0
    private var supplementalFrames = 0
    private var externalSamples = 0
    private var supplementalSamples = 0
    private var trafficByLane: [ProbeLane: [String: ProcessTraffic]] = [:]
    private var downloadByRoute: [String: [TrafficRoute: Int64]] = [:]

    func recordFrame(
        lane: ProbeLane,
        isBaseline: Bool,
        samples: [ProbeSample]
    ) -> [ProbeSample] {
        lock.lock()
        defer { lock.unlock() }

        completeFrames += 1
        if isBaseline {
            baselineFrames += 1
        }
        nonzeroSamples += samples.count
        switch lane {
        case .external:
            externalFrames += 1
            externalSamples += samples.count
        case .supplemental:
            supplementalFrames += 1
            supplementalSamples += samples.count
        }
        for sample in samples {
            var traffic = trafficByLane[lane, default: [:]][sample.delta.processName] ?? ProcessTraffic()
            traffic.download += sample.delta.downloadBytes
            traffic.upload += sample.delta.uploadBytes
            trafficByLane[lane, default: [:]][sample.delta.processName] = traffic
            downloadByRoute[sample.delta.processName, default: [:]][sample.route, default: 0] += sample.delta.downloadBytes
            attributedAppKeys.insert(sample.attributed.appKey)
            if sample.attributed.category == .proxyTransport {
                proxySamples += 1
            }
        }

        let previewCount = max(0, 20 - printedSamples)
        let preview = Array(samples.prefix(previewCount))
        printedSamples += preview.count
        return preview
    }

    func traffic(lane: ProbeLane, pid: Int32) -> ProcessTraffic {
        lock.lock()
        defer { lock.unlock() }
        var total = ProcessTraffic()
        for (token, traffic) in trafficByLane[lane, default: [:]]
        where NettopProcessToken(rawValue: token).pid == pid {
            total.download += traffic.download
            total.upload += traffic.upload
        }
        return total
    }

    func downloadByRoute(pid: Int32) -> [TrafficRoute: Int64] {
        lock.lock()
        defer { lock.unlock() }
        var total: [TrafficRoute: Int64] = [:]
        for (token, routes) in downloadByRoute where NettopProcessToken(rawValue: token).pid == pid {
            for (route, bytes) in routes {
                total[route, default: 0] += bytes
            }
        }
        return total
    }

    func recordMalformedRow() {
        lock.lock()
        malformedRows += 1
        lock.unlock()
    }

    func recordSchemaChange() {
        lock.lock()
        schemaChanges += 1
        lock.unlock()
    }

    func recordIncompatibleSchema() {
        lock.lock()
        incompatibleSchemas += 1
        lock.unlock()
    }

    func recordStorageError() {
        lock.lock()
        storageErrors += 1
        lock.unlock()
    }

    func snapshot() -> ProbeSummary {
        lock.lock()
        defer { lock.unlock() }
        return ProbeSummary(
            completeFrames: completeFrames,
            baselineFrames: baselineFrames,
            nonzeroSamples: nonzeroSamples,
            malformedRows: malformedRows,
            schemaChanges: schemaChanges,
            incompatibleSchemas: incompatibleSchemas,
            attributedApps: attributedAppKeys.count,
            proxySamples: proxySamples,
            storageErrors: storageErrors,
            externalFrames: externalFrames,
            supplementalFrames: supplementalFrames,
            externalSamples: externalSamples,
            supplementalSamples: supplementalSamples
        )
    }
}

private final class ProbeRuntime: @unchecked Sendable {
    let counters = ProbeCounters()
    let externalCollector = NettopCollector(scope: .externalProcessSummary)
    let supplementalCollector = NettopCollector(scope: .supplementalConnections)
    let proxyEndpointMonitor = SystemProxyEndpointMonitor()
    let supplementalReducer = SupplementalTrafficReducer()
    var residualTracker = SupplementalResidualTracker()
    var pendingProcessTotals: [NettopDelta] = []
    let mihomoTracker = MihomoRouteTracker()
    let mihomoClient = MihomoClient()
    var mihomoController: MihomoController?
    let resolver = SystemProcessIdentityResolver()
    let attributionCache = ProcessAttributionCache()
    let store: UsageStore
    let aggregator: UsageAggregator

    init() throws {
        let store = try UsageStore(databaseURL: URL(fileURLWithPath: ":memory:"))
        self.store = store
        self.aggregator = UsageAggregator(store: store)
    }

    func sampleDate(for rawValue: String, fallback: Date = Date()) -> Date {
        let timeParts = rawValue.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let clock = timeParts[0].split(separator: ":")
        guard clock.count == 3,
              let hour = Int(clock[0]),
              let minute = Int(clock[1]),
              let second = Int(clock[2]),
              (0..<24).contains(hour),
              (0..<60).contains(minute),
              (0..<60).contains(second) else {
            return fallback
        }

        let calendar = Calendar.autoupdatingCurrent
        var components = calendar.dateComponents([.year, .month, .day], from: fallback)
        components.hour = hour
        components.minute = minute
        components.second = second

        if timeParts.count == 2 {
            let fractional = String(timeParts[1].prefix(9)).padding(
                toLength: 9,
                withPad: "0",
                startingAt: 0
            )
            components.nanosecond = Int(fractional) ?? 0
        }
        return calendar.date(from: components) ?? fallback
    }

    func dayKey(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private func endpointLabel(_ endpoint: NettopEndpoint) -> String {
    let host = endpoint.host.contains(":") ? "[\(endpoint.host)]" : endpoint.host
    guard let port = endpoint.port else { return host }
    return "\(host):\(port)"
}

/// 运行 curl 并在等待期间继续转动主 RunLoop，让采集回调按时投递。
private func runCurl(label: String, url: String, proxy: String?, extraArguments: [String] = []) -> CurlResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    var arguments = ["-s", "-o", "/dev/null", "-w", "%{size_download} %{size_header} %{size_upload} %{size_request}"]
    if let proxy {
        arguments += ["-x", proxy]
    } else {
        arguments += ["--noproxy", "*"]
    }
    process.arguments = arguments + extraArguments + [url]
    let output = Pipe()
    process.standardOutput = output
    do {
        try process.run()
    } catch {
        print("[accuracy] case=\(label) launch_failed error=\(error.localizedDescription)")
        return nil
    }
    let pid = process.processIdentifier
    while process.isRunning {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    let fields = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: " ")
        .compactMap { Int64($0) }
    guard fields.count == 4 else {
        print("[accuracy] case=\(label) unexpected_curl_output status=\(process.terminationStatus)")
        return nil
    }
    return CurlResult(
        label: label,
        pid: pid,
        downloadBytes: fields[0] + fields[1],
        uploadBytes: fields[2] + fields[3],
        status: process.terminationStatus
    )
}

/// 按 curl 自报的 HTTP 层字节数对照通道计数。nettop 统计的是套接字层字节，
/// 还包含 TLS 记录与握手开销，因此比值略大于 1 属于正常；明显小于 1 说明漏记。
private func reportAccuracy(_ result: CurlResult, counters: ProbeCounters) -> Bool {
    // 开启 TUN 时 `--noproxy` 的直连也会经 utun 走补充通道，因此按两个通道合计。
    let external = counters.traffic(lane: .external, pid: result.pid)
    let supplemental = counters.traffic(lane: .supplemental, pid: result.pid)
    let counted = ProcessTraffic(
        download: external.download + supplemental.download,
        upload: external.upload + supplemental.upload
    )
    let ratio = result.downloadBytes > 0 ? Double(counted.download) / Double(result.downloadBytes) : 0
    let ok = result.status == 0 && ratio >= 0.97 && ratio <= 1.10
    print(
        "[accuracy] case=\(result.label) pid=\(result.pid) external_download=\(external.download) supplemental_download=\(supplemental.download) curl_download=\(result.downloadBytes) counted_download=\(counted.download) ratio=\(String(format: "%.4f", ratio)) curl_upload=\(result.uploadBytes) counted_upload=\(counted.upload) \(ok ? "OK" : "MISMATCH")"
    )
    return ok
}

/// 打印用例按出口路径的下载字节分布；`expected` 非空时要求该路径占九成以上。
private func reportRoutes(_ result: CurlResult, expected: TrafficRoute?, counters: ProbeCounters) -> Bool {
    let routes = counters.downloadByRoute(pid: result.pid)
    let total = routes.values.reduce(0, +)
    let split = TrafficRoute.allCases
        .map { "\($0.rawValue)=\(routes[$0] ?? 0)" }
        .joined(separator: " ")
    guard let expected else {
        print("[routes] case=\(result.label) \(split)")
        return true
    }
    let share = total > 0 ? Double(routes[expected] ?? 0) / Double(total) : 0
    let ok = share >= 0.9
    print("[routes] case=\(result.label) \(split) expected=\(expected.rawValue) share=\(String(format: "%.4f", share)) \(ok ? "OK" : "MISMATCH")")
    return ok
}

/// 找到运行中的 mihomo 内核并读取其控制器地址；找不到时退回默认的 127.0.0.1:9090。
private func discoverMihomoController() -> MihomoController {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["mihomo"]
    let output = Pipe()
    pgrep.standardOutput = output
    if (try? pgrep.run()) != nil {
        pgrep.waitUntilExit()
        let pids = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
        for pid in pids {
            if let arguments = MihomoControllerDiscovery.processArguments(pid: pid),
               let controller = MihomoControllerDiscovery.controller(arguments: arguments) {
                return controller
            }
        }
    }
    return MihomoController(transport: .tcp(host: "127.0.0.1", port: 9090), secret: nil)
}

private func runProbe(options: Options) -> Int32 {
    let runtime: ProbeRuntime
    do {
        runtime = try ProbeRuntime()
    } catch {
        print("[result] FAIL: 初始化 SQLite 失败：\(error.localizedDescription)")
        return 1
    }

    func handleCollectorEvent(_ event: NettopCollectorEvent, lane: ProbeLane) {
        switch event {
        case let .started(pid):
            print("[collector] lane=\(lane.rawValue) started nettop pid=\(pid)")

        case let .parser(parserEvent):
            switch parserEvent {
            case let .frameCompleted(rowCount, deltas, isBaseline):
                let acceptedDeltas: [RoutedDelta]
                switch lane {
                case .external:
                    acceptedDeltas = deltas.map { RoutedDelta(delta: $0, route: .direct) }
                case .supplemental:
                    let proxyEndpoints = runtime.proxyEndpointMonitor.currentLoopbackEndpoints
                    let tracker = runtime.mihomoTracker
                    let route: (NettopDelta) -> TrafficRoute = {
                        tracker.route(forLocalEndpoint: $0.localEndpoint) ?? .proxied
                    }
                    let residuals = isBaseline ? [] : runtime.residualTracker.residuals(
                        processTotals: runtime.pendingProcessTotals,
                        connections: deltas,
                        proxyEndpoints: proxyEndpoints,
                        at: Date(),
                        route: route
                    )
                    runtime.pendingProcessTotals = []
                    acceptedDeltas = runtime.supplementalReducer.reduceWithRoutes(
                        deltas,
                        proxyEndpoints: proxyEndpoints,
                        route: route
                    ) + residuals
                    if !residuals.isEmpty {
                        print("[parser] lane=supplemental residual_processes=\(residuals.count) residual_download=\(residuals.reduce(0) { $0 + $1.delta.downloadBytes })")
                    }
                }
                let samples = acceptedDeltas.compactMap { routed -> ProbeSample? in
                    let delta = routed.delta
                    let token = NettopProcessToken(rawValue: delta.processName)
                    let identity = runtime.resolver.resolve(token)
                    let attributed = runtime.attributionCache.attribute(identity)
                    if !TrafficFilter.shouldKeepAfterAttribution(delta, category: attributed.category) {
                        return nil
                    }

                    do {
                        try runtime.aggregator.ingest(
                            UsageDelta(
                                sampledAt: runtime.sampleDate(for: delta.sampledAt),
                                appKey: attributed.appKey,
                                displayName: attributed.displayName,
                                category: attributed.category,
                                bundleID: attributed.bundleID,
                                bundlePath: attributed.bundlePath,
                                executablePath: attributed.executablePath,
                                downloadBytes: delta.downloadBytes,
                                uploadBytes: delta.uploadBytes
                            )
                        )
                    } catch {
                        runtime.counters.recordStorageError()
                        print("[storage] ingest_failed error=\(error.localizedDescription)")
                    }

                    return ProbeSample(lane: lane, delta: delta, route: routed.route, attributed: attributed)
                }
                let preview = runtime.counters.recordFrame(
                    lane: lane,
                    isBaseline: isBaseline,
                    samples: samples
                )
                print(
                    "[parser] lane=\(lane.rawValue) frame rows=\(rowCount) baseline=\(isBaseline) raw_nonzero_deltas=\(deltas.count) accepted_deltas=\(acceptedDeltas.count)"
                )
                for sample in preview {
                    print(
                        "[sample] lane=\(sample.lane.rawValue) route=\(sample.route.rawValue) process=\(sample.delta.processName) app=\(sample.attributed.displayName) app_key=\(sample.attributed.appKey) category=\(sample.attributed.category.rawValue) launcher=\(sample.attributed.launcherName ?? "-") download_bytes=\(sample.delta.downloadBytes) upload_bytes=\(sample.delta.uploadBytes)"
                    )
                }

            case .baselineCaptured:
                break

            case let .processTotals(rows):
                runtime.pendingProcessTotals = rows

            case .malformedRow:
                runtime.counters.recordMalformedRow()

            case .schemaChanged:
                runtime.counters.recordSchemaChange()
                print("[parser] lane=\(lane.rawValue) schema_changed")

            case let .incompatibleSchema(missingColumns):
                runtime.counters.recordIncompatibleSchema()
                print("[parser] lane=\(lane.rawValue) incompatible_schema missing=\(missingColumns.joined(separator: ","))")
            }

        case let .stderr(message):
            print("[collector] lane=\(lane.rawValue) stderr=\(message)")

        case let .exited(status):
            print("[collector] lane=\(lane.rawValue) exited status=\(status)")
        }
    }

    runtime.externalCollector.onEvent = { event in
        handleCollectorEvent(event, lane: .external)
    }
    runtime.supplementalCollector.onEvent = { event in
        handleCollectorEvent(event, lane: .supplemental)
    }

    print("ByteTrace 双通道 nettop → attribution → SQLite probe")
    print("[collector] executable=\(NettopCollector.executablePath)")
    print("[collector] external_arguments=\(NettopCollectorScope.externalProcessSummary.arguments.joined(separator: " "))")
    print("[collector] supplemental_arguments=\(NettopCollectorScope.supplementalConnections.arguments.joined(separator: " "))")
    print("[collector] duration_seconds=\(options.duration)")

    runtime.proxyEndpointMonitor.start()
    defer { runtime.proxyEndpointMonitor.stop() }
    let proxyEndpoints = runtime.proxyEndpointMonitor.currentLoopbackEndpoints
        .map(endpointLabel)
        .sorted()
    print("[proxy] active_loopback_endpoints=\(proxyEndpoints.joined(separator: ","))")

    do {
        try runtime.externalCollector.start()
        try runtime.supplementalCollector.start()

        var mihomoTimer: Timer?
        if options.checksRoutes {
            let controller = discoverMihomoController()
            runtime.mihomoController = controller
            print("[routes] mihomo_controller=\(controller.transport)")
            let client = runtime.mihomoClient
            let tracker = runtime.mihomoTracker
            mihomoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task.detached {
                    do {
                        let data = try await client.get("/connections", from: controller)
                        tracker.update(with: try MihomoConnectionsParser.parse(data))
                    } catch {
                        print("[routes] mihomo_fetch_failed error=\(error.localizedDescription)")
                    }
                }
            }
        }
        defer { mihomoTimer?.invalidate() }

        var accuracyResults: [CurlResult] = []
        var routeExpectations: [String: TrafficRoute] = [:]
        if let url = options.accuracyURL {
            // 两个通道都要先经过一帧基线；外部通道 5 秒一帧，等两帧再开始。
            RunLoop.main.run(until: Date().addingTimeInterval(11))
            if let direct = runCurl(label: "direct", url: url, proxy: nil) {
                accuracyResults.append(direct)
            }
            if let endpoint = runtime.proxyEndpointMonitor.currentLoopbackEndpoints.first {
                if let proxied = runCurl(label: "system_proxy", url: url, proxy: "http://\(endpointLabel(endpoint))") {
                    accuracyResults.append(proxied)
                }
                if options.checksRoutes,
                   let ruleDirect = runCurl(
                       label: "rule_direct",
                       url: Options.ruleDirectURL,
                       proxy: "http://\(endpointLabel(endpoint))",
                       extraArguments: ["-r", "0-19999999"]
                   ) {
                    accuracyResults.append(ruleDirect)
                }
                routeExpectations = ["system_proxy": .proxyNode, "rule_direct": .proxyRuleDirect]
            } else {
                print("[accuracy] case=system_proxy skipped reason=no_system_proxy")
            }
            // curl 退出后至少再等一帧外部通道，让最后的增量落到计数里。
            RunLoop.main.run(until: Date().addingTimeInterval(7))
        } else {
            let deadline = Date().addingTimeInterval(options.duration)
            RunLoop.main.run(until: deadline)
        }

        runtime.externalCollector.stop()
        runtime.supplementalCollector.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        var accuracyPassed = true
        for result in accuracyResults {
            accuracyPassed = reportAccuracy(result, counters: runtime.counters) && accuracyPassed
        }
        if options.checksRoutes {
            var routesPassed = !accuracyResults.isEmpty
            for result in accuracyResults {
                routesPassed = reportRoutes(
                    result,
                    expected: routeExpectations[result.label],
                    counters: runtime.counters
                ) && routesPassed
            }
            print("[routes] result=\(routesPassed ? "PASS" : "FAIL")")
        }
        if options.accuracyURL != nil {
            print("[accuracy] result=\(accuracyPassed && !accuracyResults.isEmpty ? "PASS" : "FAIL")")
        }

        let flushedEntries = try runtime.aggregator.flush()
        let day = runtime.dayKey(for: Date())
        let records = try runtime.store.dailyUsage(for: day)
        let persistedDownload = records.reduce(0) { $0 + $1.downloadBytes }
        let persistedUpload = records.reduce(0) { $0 + $1.uploadBytes }
        print("[storage] flushed_entries=\(flushedEntries)")
        print("[storage] day=\(day) persisted_records=\(records.count)")
        print("[storage] persisted_download_bytes=\(persistedDownload)")
        print("[storage] persisted_upload_bytes=\(persistedUpload)")
        for record in records {
            print(
                "[storage-record] app=\(record.displayName) app_key=\(record.appKey) category=\(record.category.rawValue) download_bytes=\(record.downloadBytes) upload_bytes=\(record.uploadBytes)"
            )
        }
    } catch {
        runtime.externalCollector.stop()
        runtime.supplementalCollector.stop()
        print("[result] FAIL: collector 或 SQLite 闭环失败：\(error.localizedDescription)")
        return 1
    }

    let summary = runtime.counters.snapshot()
    print("[probe] complete_frames=\(summary.completeFrames)")
    print("[probe] baseline_frames=\(summary.baselineFrames)")
    print("[probe] nonzero_samples=\(summary.nonzeroSamples)")
    print("[probe] malformed_rows=\(summary.malformedRows)")
    print("[probe] schema_changes=\(summary.schemaChanges)")
    print("[probe] incompatible_schemas=\(summary.incompatibleSchemas)")
    print("[probe] attributed_apps=\(summary.attributedApps)")
    print("[probe] proxy_samples=\(summary.proxySamples)")
    print("[probe] storage_errors=\(summary.storageErrors)")
    print("[probe] external_frames=\(summary.externalFrames)")
    print("[probe] supplemental_frames=\(summary.supplementalFrames)")
    print("[probe] external_samples=\(summary.externalSamples)")
    print("[probe] supplemental_samples=\(summary.supplementalSamples)")

    guard summary.externalFrames > 0, summary.supplementalFrames > 0 else {
        print("[result] FAIL: 未从两个 nettop 通道都获得完整 CSV 帧")
        return 1
    }
    guard summary.incompatibleSchemas == 0 else {
        print("[result] FAIL: 存在不兼容的 nettop CSV 格式")
        return 1
    }
    guard summary.storageErrors == 0 else {
        print("[result] FAIL: 有样本未能进入本地聚合队列")
        return 1
    }

    if summary.nonzeroSamples > 0 {
        print("[result] PASS: nettop CSV → 归因 → 日聚合 → SQLite 已产生非零流量样本")
    } else {
        print("[result] PASS: 已完成 nettop CSV → 归因 → SQLite 闭环；本次没有非零流量样本")
    }
    return 0
}

/// 重启间隙补偿实测的状态；所有回调都在主线程执行。
private final class RestartCheckState: @unchecked Sendable {
    var referenceBytes: Int64 = 0
    var restartedBytes: Int64 = 0
    var recoveredBytes: Int64 = 0
    var recovery = NettopRestartGapRecovery()
    var referenceByToken: [String: Int64] = [:]
    var restartedByToken: [String: Int64] = [:]
    var recoveredByToken: [String: Int64] = [:]

    static func add(_ deltas: [NettopDelta], to map: inout [String: Int64]) {
        for delta in deltas {
            map[delta.processName, default: 0] += delta.downloadBytes + delta.uploadBytes
        }
    }

    static func total(_ deltas: [NettopDelta]) -> Int64 {
        deltas.reduce(0) { $0 + $1.downloadBytes + $1.uploadBytes }
    }
}

private func runRestartCheck(url: String) -> Int32 {
    let state = RestartCheckState()
    state.recovery.arm()
    let reference = NettopCollector(scope: .externalProcessSummary)
    let restarted = NettopCollector(scope: .externalProcessSummary)

    reference.onEvent = { event in
        if case let .parser(.frameCompleted(_, deltas, false)) = event {
            state.referenceBytes += RestartCheckState.total(deltas)
            RestartCheckState.add(deltas, to: &state.referenceByToken)
        }
    }
    restarted.onEvent = { event in
        guard case let .parser(parserEvent) = event else { return }
        switch parserEvent {
        case let .baselineCaptured(rows):
            let recovered = state.recovery.recover(fromBaseline: rows, at: Date())
            state.recoveredBytes += RestartCheckState.total(recovered)
            RestartCheckState.add(recovered, to: &state.recoveredByToken)
        case let .frameCompleted(_, deltas, false):
            state.recovery.record(deltas, at: Date())
            state.restartedBytes += RestartCheckState.total(deltas)
            RestartCheckState.add(deltas, to: &state.restartedByToken)
        default:
            break
        }
    }

    let monitor = SystemProxyEndpointMonitor()
    monitor.start()
    defer { monitor.stop() }
    let proxy = monitor.currentLoopbackEndpoints.first.map { "http://\(endpointLabel($0))" }

    do {
        try reference.start()
        try restarted.start()
    } catch {
        print("[restart-check] FAIL: 无法启动 nettop：\(error.localizedDescription)")
        return 1
    }
    RunLoop.main.run(until: Date().addingTimeInterval(11))

    // 限速下载，保证重启窗口内持续有外部流量（开启 TUN 或经系统代理时体现在代理内核上）。
    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-s", "-o", "/dev/null", "--limit-rate", "2M"]
        + (proxy.map { ["-x", $0] } ?? ["--noproxy", "*"]) + [url]
    do {
        try curl.run()
    } catch {
        print("[restart-check] FAIL: 无法启动 curl：\(error.localizedDescription)")
        return 1
    }
    RunLoop.main.run(until: Date().addingTimeInterval(4))
    restarted.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    do {
        try restarted.start()
    } catch {
        print("[restart-check] FAIL: 重启 nettop 失败：\(error.localizedDescription)")
        return 1
    }
    while curl.isRunning {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(7))
    reference.stop()
    restarted.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    for (token, bytes) in state.referenceByToken.sorted(by: { $0.value > $1.value }).prefix(6) {
        print("[restart-check] token=\(token) reference=\(bytes) restarted=\(state.restartedByToken[token] ?? 0) recovered=\(state.recoveredByToken[token] ?? 0)")
    }
    let withRecovery = state.restartedBytes + state.recoveredBytes
    let referenceTotal = Double(max(state.referenceBytes, 1))
    let missingWithout = Double(state.referenceBytes - state.restartedBytes) / referenceTotal
    let missingWith = Double(state.referenceBytes - withRecovery) / referenceTotal
    print("[restart-check] reference_bytes=\(state.referenceBytes) restarted_bytes=\(state.restartedBytes) recovered_bytes=\(state.recoveredBytes)")
    print("[restart-check] missing_without_recovery=\(String(format: "%.2f%%", missingWithout * 100)) missing_with_recovery=\(String(format: "%.2f%%", missingWith * 100))")
    let passed = state.recoveredBytes > 0 && abs(missingWith) < 0.02
    print("[restart-check] result=\(passed ? "PASS" : "FAIL")")
    return passed ? 0 : 1
}

private let probeOptions = Options(arguments: CommandLine.arguments)
if let url = probeOptions.restartCheckURL {
    exit(runRestartCheck(url: url))
}
exit(runProbe(options: probeOptions))
