import AppKit
import ByteTraceCore
import Combine
import Foundation
import ServiceManagement

enum MonitorStatus: Equatable {
    case stopped
    case starting
    case baseline
    case collecting
    case reconnecting
    case incompatible
    case failed(String)
}

struct UsageTotals: Equatable {
    let downloadBytes: Int64
    let uploadBytes: Int64

    var totalBytes: Int64 {
        let result = downloadBytes.addingReportingOverflow(uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}

@MainActor
final class ByteTraceViewModel: NSObject, ObservableObject {
    static let bundleIdentifier = "com.nanvon.ByteTrace"

    @Published private(set) var records: [DailyUsageRecord] = []
    @Published private(set) var status: MonitorStatus = .stopped
    @Published private(set) var lastError: String?
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published var showsSystemProcesses: Bool {
        didSet {
            UserDefaults.standard.set(
                showsSystemProcesses,
                forKey: Self.showSystemProcessesKey
            )
        }
    }

    let databaseURL: URL

    private static let showSystemProcessesKey = "ByteTrace.showSystemProcesses"
    private let collector: NettopCollector
    private let resolver: SystemProcessIdentityResolver
    private let attributionCache: ProcessAttributionCache
    private let store: UsageStore?
    private let aggregator: UsageAggregator?
    private var flushTimer: Timer?
    private var restartTimer: Timer?
    private var restartAttempt = 0
    private var isStarted = false
    private var wantsCollection = false
    private var isSleeping = false

    private static let restartDelays: [TimeInterval] = [1, 2, 5, 10, 30]

    override init() {
        databaseURL = UsageStore.defaultDatabaseURL(bundleIdentifier: Self.bundleIdentifier)
        collector = NettopCollector()
        resolver = SystemProcessIdentityResolver()
        attributionCache = ProcessAttributionCache()
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        let storedPreference = UserDefaults.standard.object(
            forKey: Self.showSystemProcessesKey
        ) as? Bool
        _showsSystemProcesses = Published(initialValue: storedPreference ?? true)

        var storageError: String?
        do {
            let store = try UsageStore(databaseURL: databaseURL)
            self.store = store
            aggregator = UsageAggregator(store: store)
        } catch {
            store = nil
            aggregator = nil
            storageError = "无法打开本地数据库：\(error.localizedDescription)"
        }

        super.init()
        if let storageError {
            lastError = storageError
            status = .failed(storageError)
        }
        configureCollector()
        registerWorkspaceNotifications()
        refresh()
        if store != nil {
            start()
        }
    }

    var isCollecting: Bool {
        wantsCollection
    }

    var applicationRecords: [DailyUsageRecord] {
        records.filter { $0.category == .userApp || $0.category == .unclassified }
    }

    var proxyRecords: [DailyUsageRecord] {
        records.filter { $0.category == .proxyTransport }
    }

    var systemRecords: [DailyUsageRecord] {
        records.filter { $0.category == .systemProcess }
    }

    var todayTotals: UsageTotals {
        totals(from: records.filter { $0.category != .proxyTransport })
    }

    var dayKey: String {
        Self.dayKey(for: Date())
    }

    func start() {
        guard !wantsCollection else { return }
        guard store != nil, aggregator != nil else {
            status = .failed(lastError ?? "本地存储不可用")
            return
        }

        wantsCollection = true
        lastError = nil
        startFlushTimer()
        startCollectorProcess()
    }

    func stop() {
        wantsCollection = false
        isSleeping = false
        restartTimer?.invalidate()
        restartTimer = nil
        restartAttempt = 0
        isStarted = false
        flushTimer?.invalidate()
        flushTimer = nil
        if collector.state != .stopped {
            collector.stop()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        flushNow()
        status = .stopped
        recordCollectorEvent(kind: "collector_stopped")
    }

    func shutdown() {
        wantsCollection = false
        isSleeping = false
        restartTimer?.invalidate()
        restartTimer = nil
        isStarted = false
        flushTimer?.invalidate()
        flushTimer = nil
        if collector.state != .stopped {
            collector.stop()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        flushNow()
        status = .stopped
    }

    func refresh() {
        guard let store else {
            records = []
            return
        }

        do {
            records = try store.dailyUsage(for: dayKey)
        } catch {
            lastError = "读取今日统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    func clearAllData() {
        guard let store, let aggregator else { return }

        do {
            try store.clearAll()
            aggregator.discardPending()
            records = []
            lastError = nil
        } catch {
            lastError = "清空统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = enabled
        } catch {
            lastError = "登录时启动设置失败：\(error.localizedDescription)"
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([
            databaseURL.deletingLastPathComponent()
        ])
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func configureCollector() {
        collector.onEvent = { [weak self] event in
            self?.receive(event)
        }
    }

    private func registerWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private nonisolated func receive(_ event: NettopCollectorEvent) {
        Task { @MainActor [weak self] in
            self?.handle(event)
        }
    }

    private func handle(_ event: NettopCollectorEvent) {
        switch event {
        case .started:
            status = .starting

        case let .parser(parserEvent):
            handle(parserEvent)

        case let .stderr(message):
            guard !message.isEmpty else { return }
            lastError = message
            recordCollectorEvent(kind: "collector_stderr", details: message)

        case let .exited(statusCode):
            isStarted = false
            if wantsCollection, !isSleeping {
                let message = "nettop 已退出（状态码 \(statusCode)），准备重连"
                lastError = message
                status = .reconnecting
                recordCollectorEvent(kind: "collector_exited", details: message)
                collector.stop()
                scheduleRestart()
            } else {
                if status != .incompatible {
                    status = .stopped
                }
                recordCollectorEvent(kind: "collector_exited")
            }
        }
    }

    private func handle(_ event: NettopParserEvent) {
        switch event {
        case let .frameCompleted(_, deltas, isBaseline):
            if isStarted {
                status = isBaseline ? .baseline : .collecting
            }
            guard !isBaseline else { return }
            if isStarted {
                restartAttempt = 0
                lastError = nil
            }
            for delta in deltas {
                ingest(delta)
            }

        case .malformedRow:
            break

        case .schemaChanged:
            break

        case let .incompatibleSchema(missingColumns):
            let message = "CSV 格式不兼容，缺少：\(missingColumns.joined(separator: "、"))"
            wantsCollection = false
            restartTimer?.invalidate()
            restartTimer = nil
            isStarted = false
            if collector.state != .stopped {
                collector.stop()
            }
            status = .incompatible
            lastError = message
            recordCollectorEvent(kind: "parse_schema_changed", details: message)
        }
    }

    private func ingest(_ delta: NettopDelta) {
        let token = NettopProcessToken(rawValue: delta.processName)
        let identity = resolver.resolve(token)
        let attributed = attributionCache.attribute(identity)
        guard let aggregator else { return }

        do {
            try aggregator.ingest(
                UsageDelta(
                    sampledAt: Self.sampleDate(for: delta.sampledAt),
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
            lastError = "流量样本未入队：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    private func startFlushTimer() {
        flushTimer?.invalidate()
        let timer = Timer(
            timeInterval: 5,
            target: self,
            selector: #selector(flushTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    @objc private func flushTimerFired(_ timer: Timer) {
        flushNow()
    }

    @objc private func restartTimerFired(_ timer: Timer) {
        restartTimer?.invalidate()
        restartTimer = nil
        startCollectorProcess()
    }

    @objc private func handleWillSleep(_ notification: Notification) {
        guard wantsCollection else { return }

        isSleeping = true
        restartTimer?.invalidate()
        restartTimer = nil
        isStarted = false
        if collector.state != .stopped {
            collector.stop()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        flushNow()
        status = .stopped
        recordCollectorEvent(kind: "sample_gap", details: "system_sleep")
    }

    @objc private func handleDidWake(_ notification: Notification) {
        guard wantsCollection else { return }

        isSleeping = false
        restartAttempt = 0
        lastError = nil
        status = .reconnecting
        startCollectorProcess()
    }

    private func startCollectorProcess() {
        guard wantsCollection, !isSleeping, !isStarted else { return }

        status = .starting
        do {
            try collector.start()
            isStarted = true
            recordCollectorEvent(kind: "collector_started")
        } catch {
            isStarted = false
            let message = "nettop 启动失败：\(error.localizedDescription)"
            lastError = message
            status = .reconnecting
            recordCollectorEvent(kind: "collector_error", details: message)
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard wantsCollection, !isSleeping, restartTimer == nil else { return }

        let index = min(restartAttempt, Self.restartDelays.count - 1)
        let delay = Self.restartDelays[index]
        restartAttempt = min(restartAttempt + 1, Self.restartDelays.count - 1)
        let timer = Timer(
            timeInterval: delay,
            target: self,
            selector: #selector(restartTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        restartTimer = timer
        recordCollectorEvent(
            kind: "collector_backoff",
            details: "retry_in_seconds=\(Int(delay))"
        )
    }

    private func flushNow() {
        guard let aggregator else { return }
        do {
            _ = try aggregator.flush()
            refresh()
        } catch {
            lastError = "数据库写入失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    private func recordCollectorEvent(kind: String, details: String? = nil) {
        guard let store else { return }
        try? store.recordCollectorEvent(kind: kind, details: details)
    }

    private func totals(from records: [DailyUsageRecord]) -> UsageTotals {
        var download: Int64 = 0
        var upload: Int64 = 0
        for record in records {
            let downloadResult = download.addingReportingOverflow(record.downloadBytes)
            let uploadResult = upload.addingReportingOverflow(record.uploadBytes)
            download = downloadResult.overflow ? Int64.max : downloadResult.partialValue
            upload = uploadResult.overflow ? Int64.max : uploadResult.partialValue
        }
        return UsageTotals(downloadBytes: download, uploadBytes: upload)
    }

    private static func sampleDate(for rawValue: String, fallback: Date = Date()) -> Date {
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

    private static func dayKey(for date: Date) -> String {
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
