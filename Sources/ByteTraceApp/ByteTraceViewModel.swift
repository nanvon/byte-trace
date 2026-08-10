import AppKit
import ByteTraceCore
import Combine
import Foundation
import Network
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

enum MainWindowPage: String, Hashable, Identifiable {
    case overview
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .settings: return "设置"
        }
    }
}

enum UsageTimeRange: String, CaseIterable, Identifiable {
    case last10Minutes
    case lastHour
    case today
    case thisWeek
    case thisMonth

    var id: Self { self }

    var title: String {
        switch self {
        case .last10Minutes: return "最近 10 分钟"
        case .lastHour: return "最近 1 小时"
        case .today: return "今天"
        case .thisWeek: return "本周"
        case .thisMonth: return "本月"
        }
    }

    var usesBucketSummary: Bool {
        switch self {
        case .last10Minutes, .lastHour: return true
        case .today, .thisWeek, .thisMonth: return false
        }
    }

    var usesFineGrainedTimeline: Bool {
        switch self {
        case .last10Minutes, .lastHour, .today: return true
        case .thisWeek, .thisMonth: return false
        }
    }

    func startDate(relativeTo now: Date, calendar: Calendar) -> Date {
        switch self {
        case .last10Minutes:
            return now.addingTimeInterval(-10 * 60)
        case .lastHour:
            return now.addingTimeInterval(-60 * 60)
        case .today:
            return calendar.startOfDay(for: now)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)?.start
                ?? calendar.startOfDay(for: now)
        }
    }
}

enum UsageRetentionPolicy: String, CaseIterable, Identifiable {
    case never
    case sevenDays
    case thirtyDays
    case ninetyDays

    var id: Self { self }

    var title: String {
        switch self {
        case .never: return "永不自动清理"
        case .sevenDays: return "保留 7 天"
        case .thirtyDays: return "保留 30 天"
        case .ninetyDays: return "保留 90 天"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .sevenDays: return 7 * 24 * 60 * 60
        case .thirtyDays: return 30 * 24 * 60 * 60
        case .ninetyDays: return 90 * 24 * 60 * 60
        }
    }
}

struct UsageTimelinePoint: Identifiable, Equatable {
    let start: Date
    let downloadBytes: Int64
    let uploadBytes: Int64
    /// 相邻采样间隔明显大于正常粒度时递增，用于图表上断开连线而不是画出虚假的线性上升。
    let segmentID: Int

    var id: Date { start }

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
    @Published var requestedMainWindowPage: MainWindowPage = .overview
    /// 从菜单栏点击某个应用后，主窗口概览页据此把导航栈推到该应用详情。
    @Published var pendingAppDetailKey: String?
    @Published var selectedRange: UsageTimeRange = .today {
        didSet {
            guard oldValue != selectedRange else { return }
            refreshRange()
        }
    }
    @Published private(set) var rangeRecords: [DailyUsageRecord] = []
    @Published private(set) var rangeTimeline: [UsageTimelinePoint] = []
    @Published private(set) var bucketStats: UsageBucketStats?
    private(set) var rangeBuckets: [UsageBucketRecord] = []
    private var dailyRangeRecords: [DailyUsageRecord] = []
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published var showsSystemProcesses: Bool {
        didSet {
            UserDefaults.standard.set(
                showsSystemProcesses,
                forKey: Self.showSystemProcessesKey
            )
        }
    }
    @Published var usageRetentionPolicy: UsageRetentionPolicy {
        didSet {
            guard oldValue != usageRetentionPolicy else { return }
            UserDefaults.standard.set(
                usageRetentionPolicy.rawValue,
                forKey: Self.usageRetentionPolicyKey
            )
            lastRetentionCleanupDay = nil
            applyRetentionPolicyIfNeeded(force: true)
        }
    }
    let databaseURL: URL

    private static let showSystemProcessesKey = "ByteTrace.showSystemProcesses"
    private static let usageRetentionPolicyKey = "ByteTrace.usageRetentionPolicy"
    private enum CollectorLane: Sendable {
        case external
        case loopback
    }

    private let collector: NettopCollector
    private let loopbackCollector: NettopCollector
    private let resolver: SystemProcessIdentityResolver
    private let attributionCache: ProcessAttributionCache
    private let store: UsageStore?
    private let aggregator: UsageAggregator?
    private let proxyEndpointMonitor = SystemProxyEndpointMonitor()
    private let loopbackReducer = LoopbackTrafficReducer()
    private var flushTimer: Timer?
    private var restartTimer: Timer?
    private var restartAttempt = 0
    private var isStarted = false
    private var loopbackRestartTimer: Timer?
    private var loopbackRestartAttempt = 0
    private var isLoopbackStarted = false
    private var loopbackCollectorCompatible = true
    private var loopbackLastError: String?
    private var wantsCollection = false
    private var isSleeping = false
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathMonitorQueue = DispatchQueue(
        label: "com.nanvon.ByteTrace.network-path-monitor"
    )
    private var networkPathSignature: String?
    private var networkPathSatisfied = true
    private var lastRetentionCleanupDay: String?
    private var lastUIRefreshDate: Date?

    private static let restartDelays: [TimeInterval] = [1, 2, 5, 10, 30]
    /// 诊断事件保留时长（分钟桶保留策略之外的独立上限）。
    nonisolated private static let collectorEventRetentionInterval: TimeInterval = 30 * 24 * 60 * 60
    /// 单次删除超过该阈值才 VACUUM（阻塞操作，放后台）。
    nonisolated private static let vacuumPurgeThreshold: Int64 = 10_000

    override init() {
        databaseURL = UsageStore.defaultDatabaseURL(bundleIdentifier: Self.bundleIdentifier)
        collector = NettopCollector(scope: .externalProcessSummary)
        loopbackCollector = NettopCollector(scope: .loopbackConnections)
        resolver = SystemProcessIdentityResolver()
        attributionCache = ProcessAttributionCache()
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        let storedPreference = UserDefaults.standard.object(
            forKey: Self.showSystemProcessesKey
        ) as? Bool
        _showsSystemProcesses = Published(initialValue: storedPreference ?? true)

        let storedRetentionPolicy = UserDefaults.standard.string(
            forKey: Self.usageRetentionPolicyKey
        )
        _usageRetentionPolicy = Published(
            initialValue: UsageRetentionPolicy(rawValue: storedRetentionPolicy ?? "") ?? .ninetyDays
        )

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
        configureProxyEndpointMonitor()
        registerWorkspaceNotifications()
        registerNetworkPathMonitor()
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

    var selectedRangeTotals: UsageTotals {
        totals(from: rangeRecords.filter { $0.category != .proxyTransport })
    }

    var dayKey: String {
        Self.dayKey(for: Date())
    }

    private static let todayDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter
    }()

    var todayDisplayText: String {
        Self.todayDisplayFormatter.string(from: Date())
    }

    func openAppDetail(_ appKey: String) {
        requestedMainWindowPage = .overview
        pendingAppDetailKey = appKey
    }

    func start() {
        guard !wantsCollection else { return }
        guard store != nil, aggregator != nil else {
            status = .failed(lastError ?? "本地存储不可用")
            return
        }
        guard networkPathSatisfied else {
            status = .stopped
            lastError = "当前网络不可用，恢复网络后会自动继续采集。"
            return
        }

        wantsCollection = true
        lastError = nil
        loopbackLastError = nil
        loopbackCollectorCompatible = true
        proxyEndpointMonitor.start()
        startFlushTimer()
        startCollectorProcess()
        startLoopbackCollectorProcess()
    }

    func stop() {
        wantsCollection = false
        isSleeping = false
        restartTimer?.invalidate()
        restartTimer = nil
        restartAttempt = 0
        loopbackRestartTimer?.invalidate()
        loopbackRestartTimer = nil
        loopbackRestartAttempt = 0
        isStarted = false
        isLoopbackStarted = false
        flushTimer?.invalidate()
        flushTimer = nil
        if collector.state != .stopped {
            collector.stop()
        }
        if loopbackCollector.state != .stopped {
            loopbackCollector.stop()
        }
        proxyEndpointMonitor.stop()
        flushAfterStop()
        status = .stopped
        recordCollectorEvent(kind: "collector_stopped")
    }

    func shutdown() {
        wantsCollection = false
        isSleeping = false
        restartTimer?.invalidate()
        restartTimer = nil
        loopbackRestartTimer?.invalidate()
        loopbackRestartTimer = nil
        isStarted = false
        isLoopbackStarted = false
        flushTimer?.invalidate()
        flushTimer = nil
        if collector.state != .stopped {
            collector.stop()
        }
        if loopbackCollector.state != .stopped {
            loopbackCollector.stop()
        }
        proxyEndpointMonitor.stop()
        // 退出路径必须同步排空主队列：采集器最后一帧事件是 main.async 投递的，
        // 应用终止后排队 block 不保证执行，这里转一圈 runloop 让最后一帧先入聚合器，
        // 随后 flushNow 才能把它落库（仅退出瞬间发生一次，代价可忽略）。
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        networkPathMonitor.cancel()
        flushNow(forceRefresh: true)
        status = .stopped
    }

    func refresh() {
        guard let store else {
            records = []
            rangeRecords = []
            rangeTimeline = []
            bucketStats = nil
            rangeBuckets = []
            return
        }

        do {
            applyRetentionPolicyIfNeeded()
            records = try store.dailyUsage(for: dayKey)
            try loadRange(from: store)
        } catch {
            lastError = "读取今日统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    /// 分钟桶统计（COUNT(*) 全表扫描）只在设置页按需查询，不进入 5 秒周期刷新。
    func refreshBucketStats() {
        guard let store else {
            bucketStats = nil
            return
        }
        do {
            bucketStats = try store.bucketStats()
        } catch {
            lastError = "读取分钟桶统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    func refreshRange() {
        guard let store else {
            rangeRecords = []
            rangeTimeline = []
            rangeBuckets = []
            return
        }

        do {
            try loadRange(from: store)
        } catch {
            lastError = "读取时间范围统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    func timeline(for appKey: String) -> [UsageTimelinePoint] {
        if selectedRange.usesFineGrainedTimeline, !rangeBuckets.isEmpty {
            return makeTimeline(
                from: rangeBuckets.filter {
                    $0.appKey == appKey && $0.category != .proxyTransport
                }
            )
        }

        return makeTimeline(
            from: dailyRangeRecords.filter {
                $0.appKey == appKey && $0.category != .proxyTransport
            }
        )
    }

    func clearAllData() {
        guard let store, let aggregator else { return }

        do {
            try store.clearAll()
            aggregator.discardPending()
            records = []
            rangeRecords = []
            rangeTimeline = []
            bucketStats = UsageBucketStats(
                bucketCount: 0,
                earliestBucket: nil,
                latestBucket: nil
            )
            rangeBuckets = []
            dailyRangeRecords = []
            lastRetentionCleanupDay = nil
            lastError = nil
        } catch {
            lastError = "清空统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    func exportCurrentRange(to url: URL) throws {
        let end = Date()
        let start = selectedRange.startDate(
            relativeTo: end,
            calendar: Calendar.autoupdatingCurrent
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let document = ByteTraceExportDocument(
            formatVersion: 3,
            accountingVersion: UsageStore.accountingVersion,
            product: "ByteTrace",
            exportedAt: end,
            range: ByteTraceExportDocument.Range(
                id: selectedRange.rawValue,
                title: selectedRange.title,
                start: start,
                end: end
            ),
            applicationUsage: rangeRecords.map {
                ByteTraceExportDocument.ApplicationUsage(
                    day: $0.day,
                    appKey: $0.appKey,
                    displayName: $0.displayName,
                    category: $0.category.rawValue,
                    bundleID: $0.bundleID,
                    bundlePath: $0.bundlePath,
                    executablePath: $0.executablePath,
                    downloadBytes: $0.downloadBytes,
                    uploadBytes: $0.uploadBytes,
                    totalBytes: totalBytes(for: $0),
                    sampleCount: $0.sampleCount
                )
            }
        )
        try encoder.encode(document).write(to: url, options: .atomic)
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

    /// 十进制（1000 进制）对齐访达与活动监视器的显示口径；固定小数位避免同列数字宽度参差。
    static func formatBytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes))
        let units: [(threshold: Double, suffix: String, fractionDigits: Int)] = [
            (1_000_000_000, "GB", 2),
            (1_000_000, "MB", 1),
            (1_000, "KB", 0)
        ]
        for unit in units where value >= unit.threshold {
            let scaled = value / unit.threshold
            return "\(scaled.formatted(.number.precision(.fractionLength(unit.fractionDigits)))) \(unit.suffix)"
        }
        return "\(Int(value)) B"
    }

    /// 同名不同路径的进程（如多个 node 版本）在同一个列表里无法区分，返回需要附加路径提示的应用名集合。
    static func duplicateDisplayNames(in records: [DailyUsageRecord]) -> Set<String> {
        var counts: [String: Int] = [:]
        for record in records {
            counts[record.displayName, default: 0] += 1
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    static func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func configureCollector() {
        collector.onEvent = { [weak self] event in
            self?.receive(event, lane: .external)
        }
        loopbackCollector.onEvent = { [weak self] event in
            self?.receive(event, lane: .loopback)
        }
    }

    private func configureProxyEndpointMonitor() {
        proxyEndpointMonitor.setChangeHandler { [weak self] endpoints in
            self?.receiveProxyEndpoints(endpoints)
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

    private func registerNetworkPathMonitor() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            let signature = path.availableInterfaces
                .map(\.name)
                .sorted()
                .joined(separator: ",")

            Task { @MainActor [weak self] in
                self?.handleNetworkPathUpdate(
                    isSatisfied: isSatisfied,
                    signature: signature
                )
            }
        }
        networkPathMonitor.start(queue: networkPathMonitorQueue)
    }

    private nonisolated func receive(_ event: NettopCollectorEvent, lane: CollectorLane) {
        Task { @MainActor [weak self] in
            self?.handle(event, lane: lane)
        }
    }

    private nonisolated func receiveProxyEndpoints(_ endpoints: Set<NettopEndpoint>) {
        Task { @MainActor [weak self] in
            self?.handleProxyEndpointsChanged(endpoints)
        }
    }

    private func handleProxyEndpointsChanged(_ endpoints: Set<NettopEndpoint>) {
        guard wantsCollection else { return }
        if endpoints.isEmpty {
            loopbackRestartTimer?.invalidate()
            loopbackRestartTimer = nil
            loopbackRestartAttempt = 0
            isLoopbackStarted = false
            if loopbackCollector.state != .stopped {
                loopbackCollector.stop()
            }
            loopbackLastError = nil
            if status == .collecting || status == .baseline {
                lastError = nil
            }
            recordCollectorEvent(kind: "system_proxy_disabled")
        } else {
            recordCollectorEvent(
                kind: "system_proxy_enabled",
                details: "loopback_endpoint_count=\(endpoints.count)"
            )
            startLoopbackCollectorProcess()
        }
    }

    private func handle(_ event: NettopCollectorEvent, lane: CollectorLane) {
        switch event {
        case .started:
            if lane == .external {
                status = .starting
            }

        case let .parser(parserEvent):
            handle(parserEvent, lane: lane)

        case let .stderr(message):
            guard !message.isEmpty else { return }
            if lane == .external {
                lastError = message
            }
            recordCollectorEvent(
                kind: lane == .external ? "collector_stderr" : "loopback_collector_stderr",
                details: message
            )

        case let .exited(statusCode):
            if lane == .external {
                isStarted = false
                if wantsCollection, !isSleeping, networkPathSatisfied {
                    let details = "外部流量 nettop 已退出（状态码 \(statusCode)），准备重连"
                    lastError = "统计中断，正在自动恢复…"
                    status = .reconnecting
                    recordCollectorEvent(kind: "collector_exited", details: details)
                    collector.stop()
                    flushNow()
                    scheduleRestart()
                } else {
                    if status != .incompatible {
                        status = .stopped
                    }
                    recordCollectorEvent(kind: "collector_exited")
                }
            } else {
                isLoopbackStarted = false
                if wantsCollection,
                   !isSleeping,
                   networkPathSatisfied,
                   loopbackCollectorCompatible,
                   !proxyEndpointMonitor.currentLoopbackEndpoints.isEmpty {
                    recordCollectorEvent(
                        kind: "loopback_collector_exited",
                        details: "status=\(statusCode)"
                    )
                    loopbackCollector.stop()
                    scheduleLoopbackRestart()
                }
            }
        }
    }

    private func handleNetworkPathUpdate(isSatisfied: Bool, signature: String) {
        let isInitialUpdate = networkPathSignature == nil
        let statusChanged = networkPathSatisfied != isSatisfied
        let interfaceChanged = networkPathSignature != signature

        networkPathSatisfied = isSatisfied
        networkPathSignature = signature

        guard !isInitialUpdate, (statusChanged || interfaceChanged), wantsCollection else {
            return
        }

        restartTimer?.invalidate()
        restartTimer = nil
        restartAttempt = 0
        loopbackRestartTimer?.invalidate()
        loopbackRestartTimer = nil
        loopbackRestartAttempt = 0
        isStarted = false
        isLoopbackStarted = false
        if collector.state != .stopped {
            collector.stop()
        }
        if loopbackCollector.state != .stopped {
            loopbackCollector.stop()
        }
        flushAfterStop()

        if isSatisfied {
            lastError = nil
            status = .reconnecting
            recordCollectorEvent(
                kind: "network_path_changed",
                details: signature.isEmpty ? "network_available" : signature
            )
            scheduleRestart()
            scheduleLoopbackRestart()
        } else {
            status = .stopped
            lastError = "网络不可用，已暂停采集，恢复网络后会自动继续。"
            recordCollectorEvent(kind: "network_path_lost")
        }
    }

    private func handle(_ event: NettopParserEvent, lane: CollectorLane) {
        switch event {
        case let .frameCompleted(_, deltas, isBaseline):
            if lane == .external, isStarted {
                status = isBaseline ? .baseline : .collecting
            }
            guard !isBaseline else { return }
            if lane == .external, isStarted {
                restartAttempt = 0
                lastError = loopbackLastError
            } else if lane == .loopback, isLoopbackStarted {
                loopbackRestartAttempt = 0
            }

            let acceptedDeltas: [NettopDelta]
            if lane == .loopback {
                acceptedDeltas = loopbackReducer.reduce(
                    deltas,
                    proxyEndpoints: proxyEndpointMonitor.currentLoopbackEndpoints
                )
            } else {
                acceptedDeltas = deltas
            }
            for delta in acceptedDeltas {
                ingest(delta)
            }

        case .malformedRow:
            break

        case .schemaChanged:
            break

        case let .incompatibleSchema(missingColumns):
            let message = "CSV 格式不兼容，缺少：\(missingColumns.joined(separator: "、"))"
            if lane == .external {
                wantsCollection = false
                restartTimer?.invalidate()
                restartTimer = nil
                loopbackRestartTimer?.invalidate()
                loopbackRestartTimer = nil
                isStarted = false
                isLoopbackStarted = false
                if collector.state != .stopped {
                    collector.stop()
                }
                if loopbackCollector.state != .stopped {
                    loopbackCollector.stop()
                }
                proxyEndpointMonitor.stop()
                status = .incompatible
                lastError = message
                recordCollectorEvent(kind: "parse_schema_changed", details: message)
            } else {
                loopbackCollectorCompatible = false
                isLoopbackStarted = false
                loopbackRestartTimer?.invalidate()
                loopbackRestartTimer = nil
                if loopbackCollector.state != .stopped {
                    loopbackCollector.stop()
                }
                loopbackLastError = "系统代理流量暂时无法统计：\(message)"
                lastError = loopbackLastError
                recordCollectorEvent(kind: "loopback_parse_schema_changed", details: message)
            }
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

    @objc private func loopbackRestartTimerFired(_ timer: Timer) {
        loopbackRestartTimer?.invalidate()
        loopbackRestartTimer = nil
        startLoopbackCollectorProcess()
    }

    @objc private func handleWillSleep(_ notification: Notification) {
        guard wantsCollection else { return }

        isSleeping = true
        restartTimer?.invalidate()
        restartTimer = nil
        loopbackRestartTimer?.invalidate()
        loopbackRestartTimer = nil
        isStarted = false
        isLoopbackStarted = false
        if collector.state != .stopped {
            collector.stop()
        }
        if loopbackCollector.state != .stopped {
            loopbackCollector.stop()
        }
        flushAfterStop()
        status = .stopped
        recordCollectorEvent(kind: "sample_gap", details: "system_sleep")
    }

    @objc private func handleDidWake(_ notification: Notification) {
        guard wantsCollection else { return }

        isSleeping = false
        restartAttempt = 0
        loopbackRestartAttempt = 0
        lastError = nil
        status = .reconnecting
        startCollectorProcess()
        startLoopbackCollectorProcess()
    }

    private func startCollectorProcess() {
        guard wantsCollection, !isSleeping, networkPathSatisfied, !isStarted else { return }

        status = .starting
        do {
            try collector.start()
            isStarted = true
            recordCollectorEvent(kind: "collector_started")
        } catch {
            isStarted = false
            let details = "nettop 启动失败：\(error.localizedDescription)"
            lastError = "统计启动失败：\(error.localizedDescription)"
            status = .reconnecting
            recordCollectorEvent(kind: "collector_error", details: details)
            scheduleRestart()
        }
    }

    private func startLoopbackCollectorProcess() {
        guard wantsCollection,
              !isSleeping,
              networkPathSatisfied,
              loopbackCollectorCompatible,
              !proxyEndpointMonitor.currentLoopbackEndpoints.isEmpty,
              !isLoopbackStarted else {
            return
        }

        do {
            try loopbackCollector.start()
            isLoopbackStarted = true
            recordCollectorEvent(kind: "loopback_collector_started")
        } catch {
            isLoopbackStarted = false
            recordCollectorEvent(
                kind: "loopback_collector_error",
                details: error.localizedDescription
            )
            scheduleLoopbackRestart()
        }
    }

    private func scheduleRestart() {
        guard wantsCollection, !isSleeping, networkPathSatisfied, restartTimer == nil else { return }

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

    private func scheduleLoopbackRestart() {
        guard wantsCollection,
              !isSleeping,
              networkPathSatisfied,
              loopbackCollectorCompatible,
              !proxyEndpointMonitor.currentLoopbackEndpoints.isEmpty,
              loopbackRestartTimer == nil else {
            return
        }

        let index = min(loopbackRestartAttempt, Self.restartDelays.count - 1)
        let delay = Self.restartDelays[index]
        loopbackRestartAttempt = min(loopbackRestartAttempt + 1, Self.restartDelays.count - 1)
        let timer = Timer(
            timeInterval: delay,
            target: self,
            selector: #selector(loopbackRestartTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        loopbackRestartTimer = timer
        recordCollectorEvent(
            kind: "loopback_collector_backoff",
            details: "retry_in_seconds=\(Int(delay))"
        )
    }

    private func flushNow(forceRefresh: Bool = false) {
        guard let aggregator else { return }
        do {
            _ = try aggregator.flush()
            refreshIfNeeded(force: forceRefresh)
        } catch {
            lastError = "数据库写入失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    /// 停止采集后调用：采集器最后一帧事件经 `DispatchQueue.main.async` 投递，
    /// 这里同样入主队列并排在其后，保证最后一帧先进入聚合器再落库。
    /// 退出路径不能用它（应用终止前 async block 不保证执行），shutdown() 单独同步排空。
    private func flushAfterStop() {
        DispatchQueue.main.async { [weak self] in
            self?.flushNow(forceRefresh: true)
        }
    }

    /// 落库保持 5 秒节奏；UI 刷新降频到 10 秒一次（分钟粒度数据无需秒级刷新），
    /// 停止/休眠/网络切换等终止路径强制刷新以展示最终状态。
    private func refreshIfNeeded(force: Bool) {
        let now = Date()
        guard force
                || lastUIRefreshDate == nil
                || now.timeIntervalSince(lastUIRefreshDate ?? now) >= 10 else {
            return
        }
        lastUIRefreshDate = now
        refresh()
    }

    private func applyRetentionPolicyIfNeeded(force: Bool = false) {
        guard let store, let interval = usageRetentionPolicy.interval else { return }

        let cleanupDay = Self.dayKey(for: Date())
        guard force || lastRetentionCleanupDay != cleanupDay else { return }

        let cutoff = Date().addingTimeInterval(-interval)
        let eventCutoff = Date().addingTimeInterval(-Self.collectorEventRetentionInterval)
        // 清理可能涉及数百万行的首次批量删除，必须在后台执行，不能阻塞主线程。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let deletedCount = try store.purgeBuckets(before: cutoff)
                let eventsDeleted = try store.purgeCollectorEvents(before: eventCutoff)
                if deletedCount > Self.vacuumPurgeThreshold {
                    try? store.vacuum()
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastRetentionCleanupDay = cleanupDay
                    guard deletedCount > 0 || eventsDeleted > 0 else { return }
                    self.recordCollectorEvent(
                        kind: "usage_buckets_purged",
                        details: "deleted=\(deletedCount);events=\(eventsDeleted);before=\(Int(cutoff.timeIntervalSince1970))"
                    )
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.lastError = "分钟级数据清理失败：\(error.localizedDescription)"
                    self?.recordCollectorEvent(kind: "database_error", details: self?.lastError)
                }
            }
        }
    }

    private func recordCollectorEvent(kind: String, details: String? = nil) {
        guard let store else { return }
        try? store.recordCollectorEvent(kind: kind, details: details)
    }

    private func loadRange(from store: UsageStore) throws {
        let calendar = Calendar.autoupdatingCurrent
        let end = Date()
        let start = selectedRange.startDate(relativeTo: end, calendar: calendar)

        if selectedRange.usesBucketSummary {
            let buckets = try store.bucketUsage(from: start, to: end)
            rangeBuckets = buckets
            dailyRangeRecords = []
            rangeRecords = aggregateRecords(
                buckets.map {
                    DailyUsageRecord(
                        day: Self.dayKey(for: $0.bucketStart),
                        appKey: $0.appKey,
                        displayName: $0.displayName,
                        category: $0.category,
                        bundleID: $0.bundleID,
                        bundlePath: $0.bundlePath,
                        executablePath: $0.executablePath,
                        downloadBytes: $0.downloadBytes,
                        uploadBytes: $0.uploadBytes,
                        sampleCount: $0.sampleCount
                    )
                }
            )
            rangeTimeline = makeTimeline(
                from: buckets.filter { $0.category != .proxyTransport }
            )
            return
        }

        let daily = try store.dailyUsage(
            from: Self.dayKey(for: start),
            through: Self.dayKey(for: end)
        )
        dailyRangeRecords = daily
        rangeRecords = aggregateRecords(daily)
        if selectedRange == .today {
            rangeBuckets = try store.bucketUsage(from: start, to: end)
            rangeTimeline = makeTimeline(
                from: rangeBuckets.filter { $0.category != .proxyTransport }
            )
        } else {
            rangeBuckets = []
            rangeTimeline = makeTimeline(from: daily.filter { $0.category != .proxyTransport })
        }
    }

    private func aggregateRecords(_ records: [DailyUsageRecord]) -> [DailyUsageRecord] {
        var aggregated: [String: DailyUsageRecord] = [:]
        for record in records {
            if let existing = aggregated[record.appKey] {
                aggregated[record.appKey] = merge(existing, with: record)
            } else {
                aggregated[record.appKey] = record
            }
        }
        return aggregated.values.sorted {
            totalBytes(for: $0) > totalBytes(for: $1)
        }
    }

    private func merge(
        _ existing: DailyUsageRecord,
        with record: DailyUsageRecord
    ) -> DailyUsageRecord {
        DailyUsageRecord(
            day: min(existing.day, record.day),
            appKey: existing.appKey,
            displayName: record.displayName,
            category: record.category,
            bundleID: record.bundleID,
            bundlePath: record.bundlePath,
            executablePath: record.executablePath,
            downloadBytes: saturatingAdd(existing.downloadBytes, record.downloadBytes),
            uploadBytes: saturatingAdd(existing.uploadBytes, record.uploadBytes),
            sampleCount: saturatingAdd(existing.sampleCount, record.sampleCount)
        )
    }

    private func makeTimeline(from records: [UsageBucketRecord]) -> [UsageTimelinePoint] {
        var totals: [Date: UsageTotals] = [:]
        for record in records {
            let existing = totals[record.bucketStart] ?? UsageTotals(downloadBytes: 0, uploadBytes: 0)
            totals[record.bucketStart] = UsageTotals(
                downloadBytes: saturatingAdd(existing.downloadBytes, record.downloadBytes),
                uploadBytes: saturatingAdd(existing.uploadBytes, record.uploadBytes)
            )
        }
        // 分钟粒度桶，正常相邻间隔 60 秒。
        return timelinePoints(from: totals, expectedInterval: 60)
    }

    private func makeTimeline(from records: [DailyUsageRecord]) -> [UsageTimelinePoint] {
        var totals: [Date: UsageTotals] = [:]
        for record in records {
            guard let start = Self.date(from: record.day) else { continue }
            let existing = totals[start] ?? UsageTotals(downloadBytes: 0, uploadBytes: 0)
            totals[start] = UsageTotals(
                downloadBytes: saturatingAdd(existing.downloadBytes, record.downloadBytes),
                uploadBytes: saturatingAdd(existing.uploadBytes, record.uploadBytes)
            )
        }
        // 日粒度记录，正常相邻间隔 1 天。
        return timelinePoints(from: totals, expectedInterval: 24 * 60 * 60)
    }

    /// 相邻采样点间隔超过正常粒度的 2.5 倍（例如应用休眠、未采集）时切换 segmentID，
    /// 避免 Swift Charts 把跨越空档的两个点连成一条虚假的线性上升。
    private func timelinePoints(
        from totals: [Date: UsageTotals],
        expectedInterval: TimeInterval
    ) -> [UsageTimelinePoint] {
        let gapThreshold = expectedInterval * 2.5
        var segmentID = 0
        var previousStart: Date?
        var points: [UsageTimelinePoint] = []
        for start in totals.keys.sorted() {
            guard let value = totals[start] else { continue }
            if let previousStart, start.timeIntervalSince(previousStart) > gapThreshold {
                segmentID += 1
            }
            points.append(
                UsageTimelinePoint(
                    start: start,
                    downloadBytes: value.downloadBytes,
                    uploadBytes: value.uploadBytes,
                    segmentID: segmentID
                )
            )
            previousStart = start
        }
        return points
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

    private static func date(from dayKey: String) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.autoupdatingCurrent.date(from: components)
    }

    private func totalBytes(for record: DailyUsageRecord) -> Int64 {
        let result = record.downloadBytes.addingReportingOverflow(record.uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }

    private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}
