import ByteTraceCore
import Darwin
import Foundation

private struct Options {
    let duration: TimeInterval

    init(arguments: [String]) {
        var duration: TimeInterval = 15
        var index = 1

        while index < arguments.count {
            if arguments[index] == "--duration", index + 1 < arguments.count,
               let value = TimeInterval(arguments[index + 1]), value > 0 {
                duration = value
                index += 2
            } else {
                index += 1
            }
        }

        self.duration = duration
    }
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
}

private struct ProbeSample {
    let delta: NettopDelta
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

    func recordFrame(isBaseline: Bool, samples: [ProbeSample]) -> [ProbeSample] {
        lock.lock()
        defer { lock.unlock() }

        completeFrames += 1
        if isBaseline {
            baselineFrames += 1
        }
        nonzeroSamples += samples.count
        for sample in samples {
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
            storageErrors: storageErrors
        )
    }
}

private final class ProbeRuntime: @unchecked Sendable {
    let counters = ProbeCounters()
    let collector = NettopCollector()
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

private func runProbe(options: Options) -> Int32 {
    let runtime: ProbeRuntime
    do {
        runtime = try ProbeRuntime()
    } catch {
        print("[result] FAIL: 初始化 SQLite 失败：\(error.localizedDescription)")
        return 1
    }

    runtime.collector.onEvent = { [runtime] event in
        switch event {
        case let .started(pid):
            print("[collector] started nettop pid=\(pid)")

        case let .parser(parserEvent):
            switch parserEvent {
            case let .frameCompleted(rowCount, deltas, isBaseline):
                let samples = deltas.map { delta in
                    let token = NettopProcessToken(rawValue: delta.processName)
                    let identity = runtime.resolver.resolve(token)
                    let attributed = runtime.attributionCache.attribute(identity)

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

                    return ProbeSample(delta: delta, attributed: attributed)
                }
                let preview = runtime.counters.recordFrame(isBaseline: isBaseline, samples: samples)
                print(
                    "[parser] frame rows=\(rowCount) baseline=\(isBaseline) nonzero_deltas=\(deltas.count)"
                )
                for sample in preview {
                    print(
                        "[sample] process=\(sample.delta.processName) app=\(sample.attributed.displayName) app_key=\(sample.attributed.appKey) category=\(sample.attributed.category.rawValue) download_bytes=\(sample.delta.downloadBytes) upload_bytes=\(sample.delta.uploadBytes)"
                    )
                }

            case .malformedRow:
                runtime.counters.recordMalformedRow()

            case .schemaChanged:
                runtime.counters.recordSchemaChange()
                print("[parser] schema_changed")

            case let .incompatibleSchema(missingColumns):
                runtime.counters.recordIncompatibleSchema()
                print("[parser] incompatible_schema missing=\(missingColumns.joined(separator: ","))")
            }

        case let .stderr(message):
            print("[collector] stderr=\(message)")

        case let .exited(status):
            print("[collector] exited status=\(status)")
        }
    }

    print("ByteTrace 阶段 3 nettop → attribution → SQLite probe")
    print("[collector] executable=\(NettopCollector.executablePath)")
    print("[collector] arguments=\(NettopCollector.arguments.joined(separator: " "))")
    print("[collector] duration_seconds=\(options.duration)")

    do {
        try runtime.collector.start()

        let deadline = Date().addingTimeInterval(options.duration)
        RunLoop.main.run(until: deadline)

        runtime.collector.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let flushedEntries = try runtime.aggregator.flush()
        let day = runtime.dayKey(for: Date())
        let records = try runtime.store.dailyUsage(for: day)
        let persistedDownload = records.reduce(0) { $0 + $1.downloadBytes }
        let persistedUpload = records.reduce(0) { $0 + $1.uploadBytes }
        print("[storage] flushed_entries=\(flushedEntries)")
        print("[storage] day=\(day) persisted_records=\(records.count)")
        print("[storage] persisted_download_bytes=\(persistedDownload)")
        print("[storage] persisted_upload_bytes=\(persistedUpload)")
    } catch {
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

    guard summary.completeFrames > 0 else {
        print("[result] FAIL: 未获得完整 nettop CSV 帧")
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

exit(runProbe(options: Options(arguments: CommandLine.arguments)))
