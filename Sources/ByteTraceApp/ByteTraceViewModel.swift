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

/// 主窗口里的分组；菜单栏据此展开并滚动到对应分组。
enum MainWindowSection: String, Hashable, Identifiable, CaseIterable {
    case applications
    case system
    case proxy

    var id: Self { self }

    var title: String {
        switch self {
        case .applications: return "应用"
        case .system: return "系统进程"
        case .proxy: return "代理传输"
        }
    }
}

enum UsageTimeRange: String, CaseIterable, Identifiable {
    case lastHour
    case today
    case thisWeek
    case thisMonth

    var id: Self { self }

    var title: String {
        switch self {
        case .lastHour: return "最近 1 小时"
        case .today: return "今天"
        case .thisWeek: return "本周"
        case .thisMonth: return "本月"
        }
    }

    var usesBucketSummary: Bool {
        switch self {
        case .lastHour: return true
        case .today, .thisWeek, .thisMonth: return false
        }
    }

    var usesFineGrainedTimeline: Bool {
        switch self {
        case .lastHour, .today: return true
        case .thisWeek, .thisMonth: return false
        }
    }

    func startDate(relativeTo now: Date, calendar: Calendar) -> Date {
        switch self {
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

    /// 主窗口趋势图横轴的终点：今天、本周、本月画满整个周期，未来时段留空。
    func chartEndDate(relativeTo now: Date, calendar: Calendar) -> Date {
        switch self {
        case .lastHour:
            return now
        case .today:
            return calendar.dateInterval(of: .day, for: now)?.end ?? now
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.end ?? now
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)?.end ?? now
        }
    }

    /// 主窗口趋势图每根柱子的时长。
    var chartUnit: Calendar.Component {
        switch self {
        case .lastHour: return .minute
        case .today: return .hour
        case .thisWeek, .thisMonth: return .day
        }
    }

    var chartUnitTitle: String {
        switch self {
        case .lastHour: return "每分钟"
        case .today: return "每小时"
        case .thisWeek, .thisMonth: return "每天"
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

/// 主窗口趋势图的一根柱子；`topApp*` 是该时段流量最大的应用，用于悬停浮层。
struct UsageChartBar: Identifiable, Equatable {
    let start: Date
    let end: Date
    let downloadBytes: Int64
    let uploadBytes: Int64
    let topAppName: String?
    let topAppBytes: Int64

    var id: Date { start }

    var totalBytes: Int64 {
        let result = downloadBytes.addingReportingOverflow(uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}

enum UsageObservationSurface: Hashable {
    case menuBar
    case mainOverview
}

/// mihomo 连接表读取状态，供设置页展示。
enum MihomoConnectionStatus: Equatable {
    case disabled
    case idle
    case searching
    case connected(connectionCount: Int)
    case failed(String)

    var title: String {
        switch self {
        case .disabled: return "已关闭"
        case .idle: return "等待经代理的流量"
        case .searching: return "未找到 mihomo 控制器"
        case let .connected(count): return "已连接，正在跟踪 \(count) 条连接"
        case let .failed(message): return message
        }
    }
}

/// 应用侧流量按实际出口拆成「直连 / 代理」，菜单栏与主窗口共用这一套口径。
///
/// - 直连：没有经过本机代理 / TUN（`direct`），加上进了代理内核但命中 DIRECT 规则的部分（`proxyRuleDirect`）。
/// - 代理：由代理内核经节点转发（`proxyNode`）。
/// - 出口未知（`proxied`，多为短于 mihomo 轮询间隔就结束的连接）按该应用已确认的「节点 : 规则直连」比例分摊；
///   应用自身没有已确认出口时按 `reference`（同一时间范围内全部应用）的比例分摊；
///   两者都没有（未读到 mihomo 连接表）时记入 `unknownBytes`。
/// - 路径统计上线前的流量没有路径记录，只计入 `totalBytes`，不参与比例。
struct RouteSplit: Equatable {
    let directBytes: Int64
    let proxyBytes: Int64
    let unknownBytes: Int64
    /// 全部流量，含没有路径记录的部分。
    let totalBytes: Int64

    static let empty = RouteSplit(directBytes: 0, proxyBytes: 0, unknownBytes: 0, totalBytes: 0)

    init(directBytes: Int64, proxyBytes: Int64, unknownBytes: Int64, totalBytes: Int64) {
        self.directBytes = directBytes
        self.proxyBytes = proxyBytes
        self.unknownBytes = unknownBytes
        self.totalBytes = totalBytes
    }

    /// - Parameters:
    ///   - usages: 每个应用的总字节与按路径汇总的字节。
    ///   - reference: 应用自身没有已确认出口时参照的整体路径字节。
    init(usages: [(totalBytes: Int64, routes: [TrafficRoute: Int64])], reference: [TrafficRoute: Int64]) {
        var direct = 0.0
        var proxy = 0.0
        var pending = 0.0
        var total: Int64 = 0
        for usage in usages {
            total = Self.saturatingAdd(total, usage.totalBytes)
            let routes = usage.routes
            let recorded = routes.values.reduce(0.0) { $0 + Double($1) }
            guard recorded > 0 else { continue }
            // 「最近 1 小时」用的是今天的路径数据，可能大于该时段总量，按比例收敛到总量。
            let scale = min(1, Double(usage.totalBytes) / recorded)
            let node = Double(routes[.proxyNode] ?? 0) * scale
            let ruleDirect = Double(routes[.proxyRuleDirect] ?? 0) * scale
            let unknownExit = Double(routes[.proxied] ?? 0) * scale
            direct += Double(routes[.direct] ?? 0) * scale + ruleDirect
            proxy += node
            if node + ruleDirect > 0 {
                let nodeShare = node / (node + ruleDirect)
                proxy += unknownExit * nodeShare
                direct += unknownExit * (1 - nodeShare)
            } else {
                pending += unknownExit
            }
        }

        var unknown = 0.0
        let referenceNode = Double(reference[.proxyNode] ?? 0)
        let referenceRuleDirect = Double(reference[.proxyRuleDirect] ?? 0)
        if pending > 0 {
            if referenceNode + referenceRuleDirect > 0 {
                let nodeShare = referenceNode / (referenceNode + referenceRuleDirect)
                proxy += pending * nodeShare
                direct += pending * (1 - nodeShare)
            } else {
                unknown = pending
            }
        }
        self.init(
            directBytes: Self.bytes(direct),
            proxyBytes: Self.bytes(proxy),
            unknownBytes: Self.bytes(unknown),
            totalBytes: total
        )
    }

    /// 有路径记录的流量（直连 + 代理 + 出口未知）。
    var knownBytes: Int64 {
        Self.saturatingAdd(Self.saturatingAdd(directBytes, proxyBytes), unknownBytes)
    }

    var hasKnownRoute: Bool { knownBytes > 0 }

    /// 没有路径记录的流量（路径统计启用前）。
    var unattributedBytes: Int64 { max(0, totalBytes - knownBytes) }

    /// 有路径记录的流量占全部流量的比例。
    var coverage: Double {
        guard totalBytes > 0 else { return hasKnownRoute ? 1 : 0 }
        return min(1, Double(knownBytes) / Double(totalBytes))
    }

    var isPartial: Bool { coverage < 0.99 }

    /// 大部分流量来自更新前、没有路径记录时，比例代表性不足，界面不显示百分比；字节数照常显示。
    var isRepresentative: Bool { hasKnownRoute && coverage >= 0.5 }

    /// 在有路径记录的流量里所占的比例；更新前的数据不进分母，否则比例会被压到接近 0。
    func fraction(of bytes: Int64) -> Double {
        let known = knownBytes
        guard known > 0 else { return 0 }
        return min(1, Double(bytes) / Double(known))
    }

    var proxyFraction: Double { fraction(of: proxyBytes) }

    private static func bytes(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(Int64.max) ? Int64.max : Int64(value.rounded())
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }
}

@MainActor
final class ByteTraceViewModel: NSObject, ObservableObject {
    static let bundleIdentifier = "com.nanvon.ByteTrace"

    @Published private(set) var records: [DailyUsageRecord] = []
    /// 今日应用侧流量的直连 / 代理拆分，供菜单栏今日卡片使用；与主窗口「今天」范围同一口径。
    @Published private(set) var todayRouteSplit: RouteSplit = .empty
    @Published private(set) var status: MonitorStatus = .stopped
    @Published private(set) var lastError: String?
    /// 菜单栏请求主窗口展开并滚动到的分组；主窗口处理后置回 nil。
    @Published var requestedMainWindowSection: MainWindowSection?
    /// 从菜单栏点击某个应用后，主窗口据此选中该行并打开详情栏；处理后置回 nil。
    @Published var pendingAppDetailKey: String?
    @Published var selectedRange: UsageTimeRange = .today {
        didSet {
            guard oldValue != selectedRange else { return }
            if observedUsageSurfaces.contains(.mainOverview) {
                refreshOverview()
            }
        }
    }
    /// 菜单栏面板的最近 1 小时分钟趋势（不含代理传输）。
    @Published private(set) var menuBarHourTimeline: [UsageTimelinePoint] = []
    @Published private(set) var rangeRecords: [DailyUsageRecord] = []
    /// 命令行进程最近一次的启动者（appKey → 名称），供列表副标题使用。
    @Published private(set) var launcherNames: [String: String] = [:]
    @Published private(set) var rangeBars: [UsageChartBar] = []
    @Published private(set) var detailTimeline: [UsageTimelinePoint] = []
    @Published private(set) var bucketStats: UsageBucketStats?
    /// 当前时间范围内各应用按路径汇总的字节数（日粒度；「最近 1 小时」按今天统计）。
    @Published private(set) var rangeRouteUsage: [String: [TrafficRoute: Int64]] = [:]
    /// `rangeRouteUsage` 按路径合并后的总量，作为出口未知流量的分摊参照。
    private var rangeRouteReference: [TrafficRoute: Int64] = [:]
    private var dailyRangeRecords: [DailyUsageRecord] = []
    private var activeDetailAppKey: String?
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
    @Published var readsMihomoConnections: Bool {
        didSet {
            guard oldValue != readsMihomoConnections else { return }
            UserDefaults.standard.set(readsMihomoConnections, forKey: Self.readsMihomoConnectionsKey)
            updateMihomoPolling()
        }
    }
    @Published private(set) var mihomoStatus: MihomoConnectionStatus = .idle
    let databaseURL: URL

    private static let showSystemProcessesKey = "ByteTrace.showSystemProcesses"
    private static let usageRetentionPolicyKey = "ByteTrace.usageRetentionPolicy"
    private static let detectedProxyExecutablesKey = "ByteTrace.detectedProxyExecutables"
    private static let readsMihomoConnectionsKey = "ByteTrace.readsMihomoConnections"
    /// 只在最近有经代理流量时轮询，空闲时不访问控制器。
    private static let mihomoActiveWindow: TimeInterval = 30
    private static let mihomoPollInterval: TimeInterval = 2
    private static let mihomoDiscoveryInterval: TimeInterval = 30
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
    private let supplementalReducer = SupplementalTrafficReducer()
    private let instanceLock = DataDirectoryLock(
        url: DataDirectoryLock.defaultLockURL(bundleIdentifier: ByteTraceViewModel.bundleIdentifier)
    )
    private var instanceLockRetryTimer: Timer?
    private var instanceLockWaitStartedAt: Date?
    /// 已检查过的系统代理监听进程令牌（`名称.pid`），避免每帧重复解析身份。
    private var checkedProxyListenerTokens: Set<String> = []
    private var detectedProxyExecutables: [String]
    private let mihomoClient = MihomoClient()
    private let mihomoRouteTracker = MihomoRouteTracker()
    private var externalGapRecovery = NettopRestartGapRecovery()
    private var supplementalResidualTracker = SupplementalResidualTracker()
    private var pendingSupplementalProcessTotals: [NettopDelta] = []
    private var pendingLauncherNames: [String: String] = [:]
    private var mihomoController: MihomoController?
    private var mihomoTimer: Timer?
    private var mihomoFetchInFlight = false
    private var lastMihomoDiscoveryAt: Date?
    private var lastSupplementalTrafficAt: Date?
    /// 最近出现过流量的代理传输进程 pid，用来读取内核命令行参数找控制器。
    private var proxyProcessPIDs: [Int32] = []
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
    private var retentionCleanupInProgress = false
    private var retentionCleanupNeedsRerun = false
    private let retentionQueue = DispatchQueue(
        label: "com.nanvon.ByteTrace.retention",
        qos: .utility
    )
    private var lastTodayRefreshDate: Date?
    private var lastRangeRefreshDate: Date?
    /// 每种界面只触发自己真正需要的查询，避免菜单栏连带加载完整分钟趋势。
    private var observedUsageSurfaces: Set<UsageObservationSurface> = []

    private static let restartDelays: [TimeInterval] = [1, 2, 5, 10, 30]
    /// 诊断事件保留时长（分钟桶保留策略之外的独立上限）。
    nonisolated private static let collectorEventRetentionInterval: TimeInterval = 30 * 24 * 60 * 60
    override init() {
        databaseURL = UsageStore.defaultDatabaseURL(bundleIdentifier: Self.bundleIdentifier)
        collector = NettopCollector(scope: .externalProcessSummary)
        loopbackCollector = NettopCollector(scope: .supplementalConnections)
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
        _readsMihomoConnections = Published(
            initialValue: UserDefaults.standard.object(forKey: Self.readsMihomoConnectionsKey) as? Bool ?? true
        )
        detectedProxyExecutables = UserDefaults.standard.stringArray(
            forKey: Self.detectedProxyExecutablesKey
        ) ?? []
        for path in detectedProxyExecutables {
            attributionCache.registerDetectedProxy(executablePath: path)
        }

        var storageError: String?
        do {
            let store = try UsageStore(databaseURL: databaseURL)
            self.store = store
            aggregator = UsageAggregator(store: store)
            _launcherNames = Published(initialValue: (try? store.launcherNames()) ?? [:])
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
        refreshToday()
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

    var proxyTotals: UsageTotals {
        totals(from: proxyRecords)
    }

    var selectedRangeTotals: UsageTotals {
        totals(from: rangeRecords.filter { $0.category != .proxyTransport })
    }

    var selectedRangeProxyTotals: UsageTotals {
        totals(from: rangeRecords.filter { $0.category == .proxyTransport })
    }

    var dayKey: String {
        Self.dayKey(for: Date())
    }

    func openAppDetail(_ appKey: String) {
        pendingAppDetailKey = appKey
    }

    /// 界面开始展示统计数据时调用。每个 surface 只加载自己需要的数据。
    func beginObservingUsage(_ surface: UsageObservationSurface) {
        guard observedUsageSurfaces.insert(surface).inserted else { return }
        switch surface {
        case .menuBar:
            lastTodayRefreshDate = nil
            refreshToday()
        case .mainOverview:
            lastRangeRefreshDate = nil
            refreshOverview()
        }
    }

    func endObservingUsage(_ surface: UsageObservationSurface) {
        observedUsageSurfaces.remove(surface)
    }

    func beginObservingAppDetail(_ appKey: String) {
        activeDetailAppKey = appKey
        refreshDetailTimeline(for: appKey)
    }

    func endObservingAppDetail(_ appKey: String) {
        guard activeDetailAppKey == appKey else { return }
        activeDetailAppKey = nil
        detailTimeline = []
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
        guard instanceLock.tryAcquire() else {
            waitForInstanceLock()
            return
        }
        cancelInstanceLockWait()

        wantsCollection = true
        externalGapRecovery.arm()
        supplementalResidualTracker.reset()
        lastError = nil
        loopbackLastError = nil
        loopbackCollectorCompatible = true
        proxyEndpointMonitor.start()
        startFlushTimer()
        startCollectorProcess()
        startLoopbackCollectorProcess()
        updateMihomoPolling()
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
        cancelInstanceLockWait()
        instanceLock.release()
        externalGapRecovery.reset()
        updateMihomoPolling()
        status = .stopped
        recordCollectorEvent(kind: "collector_stopped")
    }

    /// 另一个实例（已安装版与 Xcode 运行版、或更新重启时的旧进程）持有数据目录锁时，
    /// 本实例不采集。前 15 秒每 0.5 秒重试，覆盖旧实例退出前的落库；之后每 10 秒重试，
    /// 另一个实例退出后自动接管。
    private func waitForInstanceLock() {
        if instanceLockWaitStartedAt == nil {
            instanceLockWaitStartedAt = Date()
            status = .starting
            recordCollectorEvent(kind: "instance_lock_busy")
        }
        guard instanceLockRetryTimer == nil else { return }
        scheduleInstanceLockRetry(interval: 0.5)
    }

    private func scheduleInstanceLockRetry(interval: TimeInterval) {
        instanceLockRetryTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.instanceLockRetryTimerFired()
            }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        instanceLockRetryTimer = timer
    }

    private func instanceLockRetryTimerFired() {
        guard !wantsCollection else {
            cancelInstanceLockWait()
            return
        }
        if instanceLock.tryAcquire() {
            instanceLock.release()
            cancelInstanceLockWait()
            start()
            return
        }
        let waited = Date().timeIntervalSince(instanceLockWaitStartedAt ?? Date())
        if waited >= 15, instanceLockRetryTimer?.timeInterval ?? 0 < 10 {
            let message = "另一个 ByteTrace 正在采集同一份数据，本实例不会重复记录；另一个实例退出后会自动接管。"
            lastError = message
            status = .failed(message)
            scheduleInstanceLockRetry(interval: 10)
        }
    }

    private func cancelInstanceLockWait() {
        instanceLockRetryTimer?.invalidate()
        instanceLockRetryTimer = nil
        instanceLockWaitStartedAt = nil
    }

    /// 更新退出前确认最终采样已保存；失败时交由更新窗口提供重试。
    func prepareForUpdate() throws {
        let wasCollecting = isCollecting
        stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        do {
            _ = try aggregator?.flush()
        } catch {
            if wasCollecting { start() }
            throw error
        }
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
        cancelInstanceLockWait()
        instanceLock.release()
        externalGapRecovery.reset()
        updateMihomoPolling()
        status = .stopped
    }

    func refresh() {
        guard let store else {
            records = []
            todayRouteSplit = .empty
            menuBarHourTimeline = []
            rangeRecords = []
            rangeBars = []
            detailTimeline = []
            bucketStats = nil
            return
        }

        do {
            let today = try loadToday(from: store)
            try loadMenuBarHourTimeline(from: store)
            try loadRange(
                from: store,
                cachedToday: selectedRange == .today ? today : nil
            )
            let now = Date()
            lastTodayRefreshDate = now
            lastRangeRefreshDate = now
        } catch {
            lastError = "读取今日统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    func refreshToday() {
        guard let store else {
            records = []
            todayRouteSplit = .empty
            menuBarHourTimeline = []
            return
        }
        do {
            _ = try loadToday(from: store)
            try loadMenuBarHourTimeline(from: store)
            lastTodayRefreshDate = Date()
        } catch {
            lastError = "读取今日统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    func refreshOverview() {
        guard let store else {
            rangeRecords = []
            rangeBars = []
            detailTimeline = []
            return
        }
        do {
            let today = selectedRange == .today ? try loadToday(from: store) : nil
            try loadRange(from: store, cachedToday: today)
            let now = Date()
            lastRangeRefreshDate = now
            if today != nil { lastTodayRefreshDate = now }
        } catch {
            lastError = "读取时间范围统计失败：\(error.localizedDescription)"
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
        refreshOverview()
    }

    /// 路径数据按日汇总；「最近 1 小时」只能用今天的拆分近似。
    var routeBreakdownUsesToday: Bool {
        selectedRange == .lastHour
    }

    func routeSplit(for records: [DailyUsageRecord]) -> RouteSplit {
        RouteSplit(
            usages: records.filter { $0.category != .proxyTransport }.map {
                (totalBytes(for: $0), rangeRouteUsage[$0.appKey] ?? [:])
            },
            reference: rangeRouteReference
        )
    }

    /// 代理外层流量按应用侧「代理节点 / 规则直连」比例估算去向。没有 mihomo 路径数据时返回 nil。
    func proxyTransportEstimate(proxyBytes: Int64) -> RouteSplit? {
        let node = rangeRouteReference[.proxyNode] ?? 0
        let ruleDirect = rangeRouteReference[.proxyRuleDirect] ?? 0
        let unknownExit = rangeRouteReference[.proxied] ?? 0
        let known = saturatingAdd(node, ruleDirect)
        guard proxyBytes > 0, known > 0 else { return nil }
        // 应用侧有路径记录的经代理流量不足代理外层的一半时（多为更新前的数据），比例代表性不足，不估算。
        guard Double(saturatingAdd(known, unknownExit)) >= Double(proxyBytes) * 0.5 else { return nil }
        let nodeBytes = Int64(Double(proxyBytes) * Double(node) / Double(known))
        return RouteSplit(
            directBytes: proxyBytes - nodeBytes,
            proxyBytes: nodeBytes,
            unknownBytes: 0,
            totalBytes: proxyBytes
        )
    }

    func timeline(for appKey: String) -> [UsageTimelinePoint] {
        activeDetailAppKey == appKey ? detailTimeline : []
    }

    func clearAllData() {
        guard let store, let aggregator else { return }

        do {
            try store.clearAll()
            aggregator.discardPending()
            pendingLauncherNames = [:]
            launcherNames = [:]
            records = []
            todayRouteSplit = .empty
            menuBarHourTimeline = []
            rangeRecords = []
            rangeRouteUsage = [:]
            rangeRouteReference = [:]
            rangeBars = []
            bucketStats = UsageBucketStats(
                bucketCount: 0,
                earliestBucket: nil,
                latestBucket: nil
            )
            dailyRangeRecords = []
            detailTimeline = []
            activeDetailAppKey = nil
            lastRetentionCleanupDay = nil
            lastError = nil
        } catch {
            lastError = "清空统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    func exportCurrentRange(to url: URL) throws {
        if let store {
            let today = selectedRange == .today ? try loadToday(from: store) : nil
            try loadRange(from: store, cachedToday: today)
        }
        let end = Date()
        let start = selectedRange.startDate(
            relativeTo: end,
            calendar: Calendar.autoupdatingCurrent
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let document = ByteTraceExportDocument(
            formatVersion: 4,
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
                    sampleCount: $0.sampleCount,
                    routeBytes: Dictionary(
                        uniqueKeysWithValues: (rangeRouteUsage[$0.appKey] ?? [:]).map {
                            ($0.key.rawValue, $0.value)
                        }
                    )
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

    /// 列表副标题：系统进程的中文用途说明，命令行进程的启动者。
    func subtitle(for record: DailyUsageRecord) -> String? {
        var parts: [String] = []
        if record.category != .userApp,
           let description = SystemProcessDescriptions.description(forExecutablePath: record.executablePath) {
            parts.append(description)
        }
        if let launcher = launcherNames[record.appKey], launcher != record.displayName {
            parts.append("由 \(launcher) 启动")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 详情页副标题：在列表副标题前注明解析前就退出、没有路径的进程。
    func detailSubtitle(for record: DailyUsageRecord) -> String? {
        var parts: [String] = []
        if record.appKey.hasPrefix("process:"),
           record.bundlePath == nil, record.executablePath == nil {
            parts.append("进程已退出，未能识别来源")
        }
        if let subtitle = subtitle(for: record) {
            parts.append(subtitle)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            recordCollectorEvent(kind: "system_proxy_disabled")
        } else {
            recordCollectorEvent(
                kind: "system_proxy_enabled",
                details: "loopback_endpoint_count=\(endpoints.count)"
            )
        }
        // 补充通道还负责 utun/TUN 应用侧流量，因此系统代理关闭时也必须运行。
        startLoopbackCollectorProcess()
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
                   loopbackCollectorCompatible {
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
        case let .baselineCaptured(rows):
            guard lane == .external else { return }
            let recovered = externalGapRecovery.recover(fromBaseline: rows, at: Date())
            guard !recovered.isEmpty else { return }
            var download: Int64 = 0
            var upload: Int64 = 0
            for delta in recovered {
                download = saturatingAdd(download, delta.downloadBytes)
                upload = saturatingAdd(upload, delta.uploadBytes)
                ingest(delta, route: .direct)
            }
            recordCollectorEvent(
                kind: "collector_gap_recovered",
                details: "processes=\(recovered.count) download=\(download) upload=\(upload)"
            )

        case let .processTotals(rows):
            if lane == .loopback {
                pendingSupplementalProcessTotals = rows
            }

        case let .frameCompleted(_, deltas, isBaseline):
            let processTotals = lane == .loopback ? pendingSupplementalProcessTotals : []
            if lane == .loopback {
                pendingSupplementalProcessTotals = []
            }
            if lane == .external, isStarted {
                status = isBaseline ? .baseline : .collecting
            }
            guard !isBaseline else { return }
            if lane == .external {
                externalGapRecovery.record(deltas, at: Date())
            }
            if lane == .external, isStarted {
                restartAttempt = 0
                lastError = loopbackLastError
            } else if lane == .loopback, isLoopbackStarted {
                loopbackRestartAttempt = 0
            }

            let acceptedDeltas: [RoutedDelta]
            if lane == .loopback {
                let proxyEndpoints = proxyEndpointMonitor.currentLoopbackEndpoints
                detectProxyListeners(in: deltas, proxyEndpoints: proxyEndpoints)
                let route: (NettopDelta) -> TrafficRoute = { [weak self] in
                    self?.supplementalRoute(for: $0) ?? .proxied
                }
                let residuals = supplementalResidualTracker.residuals(
                    processTotals: processTotals,
                    connections: deltas,
                    proxyEndpoints: proxyEndpoints,
                    at: Date(),
                    route: route
                )
                acceptedDeltas = supplementalReducer.reduceWithRoutes(
                    deltas,
                    proxyEndpoints: proxyEndpoints,
                    route: route
                ) + residuals
            } else {
                acceptedDeltas = deltas.map { RoutedDelta(delta: $0, route: .direct) }
            }
            if lane == .loopback, !acceptedDeltas.isEmpty {
                lastSupplementalTrafficAt = Date()
                if mihomoTimer == nil {
                    updateMihomoPolling()
                }
            }
            for routed in acceptedDeltas {
                ingest(routed.delta, route: routed.route)
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
                loopbackLastError = "系统代理与 TUN 补充流量暂时无法统计：\(message)"
                lastError = loopbackLastError
                recordCollectorEvent(kind: "loopback_parse_schema_changed", details: message)
            }
        }
    }

    /// 监听系统代理端口的进程就是代理内核。静态规则没覆盖到的（自编译内核、
    /// 其他客户端）在这里登记为代理传输，避免它的外层流量混进应用总量。
    private func detectProxyListeners(
        in deltas: [NettopDelta],
        proxyEndpoints: Set<NettopEndpoint>
    ) {
        let tokens = TrafficFilter.proxyListenerProcessTokens(
            in: deltas,
            proxyEndpoints: proxyEndpoints
        )
        guard !tokens.isEmpty else { return }
        if checkedProxyListenerTokens.count > 256 {
            checkedProxyListenerTokens.removeAll()
        }
        for rawToken in tokens where checkedProxyListenerTokens.insert(rawToken).inserted {
            let identity = resolver.resolve(NettopProcessToken(rawValue: rawToken))
            guard attributionCache.attribute(identity).category != .proxyTransport,
                  let executablePath = identity.executablePath,
                  attributionCache.registerDetectedProxy(executablePath: executablePath) else {
                continue
            }
            detectedProxyExecutables.append(executablePath)
            UserDefaults.standard.set(
                detectedProxyExecutables,
                forKey: Self.detectedProxyExecutablesKey
            )
            recordCollectorEvent(
                kind: "proxy_process_detected",
                details: URL(fileURLWithPath: executablePath).lastPathComponent
            )
        }
    }

    /// 补充通道单条连接的出口路径。
    private func supplementalRoute(for delta: NettopDelta) -> TrafficRoute {
        guard readsMihomoConnections else { return .proxied }
        return mihomoRouteTracker.route(forLocalEndpoint: delta.localEndpoint) ?? .proxied
    }

    // MARK: - mihomo 连接表

    private func updateMihomoPolling() {
        guard readsMihomoConnections, wantsCollection else {
            mihomoTimer?.invalidate()
            mihomoTimer = nil
            mihomoController = nil
            mihomoRouteTracker.removeAll()
            mihomoStatus = readsMihomoConnections ? .idle : .disabled
            return
        }
        if mihomoStatus == .disabled { mihomoStatus = .idle }
        // 只在最近有补充通道流量时运行定时器；空闲时停掉，避免每 2 秒的无效唤醒。
        guard mihomoTimer == nil, hasRecentSupplementalTraffic else { return }
        let timer = Timer(timeInterval: Self.mihomoPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.mihomoTimerFired()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        mihomoTimer = timer
        mihomoTimerFired()
    }

    private var hasRecentSupplementalTraffic: Bool {
        guard let lastSupplementalTrafficAt else { return false }
        return Date().timeIntervalSince(lastSupplementalTrafficAt) <= Self.mihomoActiveWindow
    }

    private func mihomoTimerFired() {
        guard readsMihomoConnections, wantsCollection, !mihomoFetchInFlight else { return }
        guard hasRecentSupplementalTraffic else {
            mihomoTimer?.invalidate()
            mihomoTimer = nil
            if case .connected = mihomoStatus { mihomoStatus = .idle }
            return
        }

        if mihomoController == nil {
            let now = Date()
            if let lastMihomoDiscoveryAt,
               now.timeIntervalSince(lastMihomoDiscoveryAt) < Self.mihomoDiscoveryInterval {
                return
            }
            lastMihomoDiscoveryAt = now
            mihomoController = discoverMihomoController()
            guard mihomoController != nil else {
                mihomoStatus = .searching
                return
            }
        }
        guard let controller = mihomoController else { return }

        mihomoFetchInFlight = true
        let client = mihomoClient
        let tracker = mihomoRouteTracker
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<Int, Error>
            do {
                let data = try await client.get("/connections", from: controller)
                let snapshot = try MihomoConnectionsParser.parse(data)
                tracker.update(with: snapshot)
                result = .success(snapshot.connections.count)
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.finishMihomoFetch(result, controller: controller)
            }
        }
    }

    private func finishMihomoFetch(_ result: Result<Int, Error>, controller: MihomoController) {
        mihomoFetchInFlight = false
        switch result {
        case let .success(count):
            if mihomoStatus != .connected(connectionCount: count) {
                if case .connected = mihomoStatus {} else {
                    recordCollectorEvent(kind: "mihomo_connected")
                }
                mihomoStatus = .connected(connectionCount: count)
            }
        case let .failure(error):
            // 内核重启后地址可能变化：清掉控制器，下一轮按间隔重新发现。
            if mihomoController == controller { mihomoController = nil }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if mihomoStatus != .failed(message) {
                recordCollectorEvent(kind: "mihomo_unavailable", details: message)
            }
            mihomoStatus = .failed(message)
        }
    }

    /// 先读代理传输进程的命令行参数与配置；都没有时尝试 mihomo 与 Clash Verge 的默认地址。
    private func discoverMihomoController() -> MihomoController? {
        for pid in proxyProcessPIDs.reversed() {
            if let arguments = MihomoControllerDiscovery.processArguments(pid: pid),
               let controller = MihomoControllerDiscovery.controller(arguments: arguments) {
                return controller
            }
        }
        let vergeSocket = "/tmp/verge/verge-mihomo.sock"
        if FileManager.default.fileExists(atPath: vergeSocket) {
            return MihomoController(transport: .unix(path: vergeSocket), secret: nil)
        }
        guard !proxyProcessPIDs.isEmpty else { return nil }
        return MihomoController(transport: .tcp(host: "127.0.0.1", port: 9090), secret: nil)
    }

    private func noteProxyProcess(pid: Int32) {
        guard proxyProcessPIDs.last != pid else { return }
        let isNew = !proxyProcessPIDs.contains(pid)
        proxyProcessPIDs.removeAll { $0 == pid }
        proxyProcessPIDs.append(pid)
        // 新识别出代理内核时立即重新查找控制器，不等 30 秒重试间隔。
        if isNew, mihomoController == nil {
            lastMihomoDiscoveryAt = nil
        }
        if proxyProcessPIDs.count > 8 {
            proxyProcessPIDs.removeFirst(proxyProcessPIDs.count - 8)
        }
    }

    private func ingest(_ delta: NettopDelta, route: TrafficRoute) {
        let token = NettopProcessToken(rawValue: delta.processName)
        let identity = resolver.resolve(token)
        let attributed = attributionCache.attribute(identity)
        // undefined 接口同时包含应用侧 TUN 连接与代理进程的镜像连接。
        // 应用侧记入对应应用；代理镜像丢弃，代理外层仍由 external 通道单独统计。
        if !TrafficFilter.shouldKeepAfterAttribution(delta, category: attributed.category) {
            return
        }
        if attributed.category == .proxyTransport, let pid = attributed.pid {
            noteProxyProcess(pid: pid)
        }
        if let launcherName = attributed.launcherName,
           launcherNames[attributed.appKey] != launcherName {
            pendingLauncherNames[attributed.appKey] = launcherName
        }
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
                    uploadBytes: delta.uploadBytes,
                    route: attributed.category == .proxyTransport ? nil : route
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
        // 允许系统把这次唤醒与其他定时器合并，减少闲置唤醒次数（菜单栏常驻工具的能耗大头
        // 之一）。落库晚最多 1 秒不影响任何统计口径：聚合结果仍在内存里，一条不丢。
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    @objc private func flushTimerFired(_ timer: Timer) {
        flushNow()
        // 保留策略从 refresh() 移到这里：refresh() 受可见性门控，挂在那边会让清理永不执行。
        // 内部有 lastRetentionCleanupDay 日级守卫，每天最多真正执行一次。
        // 必须排在 flushNow() 之后：清理在后台队列执行、与落库共用 UsageStore 的锁，
        // 先完成本次落库能把两者的竞争窗口压到最小。
        applyRetentionPolicyIfNeeded()
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
            if !pendingLauncherNames.isEmpty, let store {
                try store.recordLaunchers(pendingLauncherNames)
                launcherNames.merge(pendingLauncherNames) { _, new in new }
                pendingLauncherNames = [:]
            }
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

    /// 落库保持 5 秒节奏；每种可见界面只刷新自己需要的数据。
    private func refreshIfNeeded(force: Bool) {
        if force {
            refresh()
            return
        }
        guard let store, !observedUsageSurfaces.isEmpty else { return }
        let now = Date()
        let todayDue = observedUsageSurfaces.contains(.menuBar)
            && (lastTodayRefreshDate == nil
                || now.timeIntervalSince(lastTodayRefreshDate ?? now) >= 10)
        let rangeDue = observedUsageSurfaces.contains(.mainOverview)
            && (lastRangeRefreshDate == nil
                || now.timeIntervalSince(lastRangeRefreshDate ?? now) >= 10)
        guard todayDue || rangeDue else { return }

        do {
            var today: [DailyUsageRecord]?
            if todayDue || (rangeDue && selectedRange == .today) {
                today = try loadToday(from: store)
                lastTodayRefreshDate = now
            }
            if todayDue {
                try loadMenuBarHourTimeline(from: store)
            }
            if rangeDue {
                try loadRange(
                    from: store,
                    cachedToday: selectedRange == .today ? today : nil
                )
                lastRangeRefreshDate = now
            }
        } catch {
            lastError = "读取统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    private func applyRetentionPolicyIfNeeded(force: Bool = false) {
        guard let store, let interval = usageRetentionPolicy.interval else { return }

        let cleanupDay = Self.dayKey(for: Date())
        guard force || lastRetentionCleanupDay != cleanupDay else { return }
        guard !retentionCleanupInProgress else {
            if force { retentionCleanupNeedsRerun = true }
            return
        }
        retentionCleanupInProgress = true

        let cutoff = Date().addingTimeInterval(-interval)
        let eventCutoff = Date().addingTimeInterval(-Self.collectorEventRetentionInterval)
        // 串行队列 + in-flight 门控保证同一时刻只有一个维护任务。DELETE 后的空闲页由
        // SQLite 后续写入复用，不再按删除行数自动 VACUUM，避免周期性重写整个数据库。
        retentionQueue.async { [weak self] in
            do {
                let deletedCount = try store.purgeBuckets(before: cutoff)
                let eventsDeleted = try store.purgeCollectorEvents(before: eventCutoff)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastRetentionCleanupDay = cleanupDay
                    if deletedCount > 0 || eventsDeleted > 0 {
                        self.recordCollectorEvent(
                            kind: "usage_buckets_purged",
                            details: "deleted=\(deletedCount);events=\(eventsDeleted);before=\(Int(cutoff.timeIntervalSince1970))"
                        )
                    }
                    self.finishRetentionCleanup()
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastError = "分钟级数据清理失败：\(error.localizedDescription)"
                    self.recordCollectorEvent(kind: "database_error", details: self.lastError)
                    self.finishRetentionCleanup()
                }
            }
        }
    }

    private func finishRetentionCleanup() {
        retentionCleanupInProgress = false
        guard retentionCleanupNeedsRerun else { return }
        retentionCleanupNeedsRerun = false
        applyRetentionPolicyIfNeeded(force: true)
    }

    private func recordCollectorEvent(kind: String, details: String? = nil) {
        guard let store else { return }
        try? store.recordCollectorEvent(kind: kind, details: details)
    }

    @discardableResult
    private func loadToday(from store: UsageStore) throws -> [DailyUsageRecord] {
        let today = dayKey
        let newRecords = try store.dailyUsage(for: today)
        let appRecords = newRecords.filter { $0.category != .proxyTransport }
        let appKeys = Set(appRecords.map(\.appKey))
        var appRoutes: [String: [TrafficRoute: Int64]] = [:]
        var reference: [TrafficRoute: Int64] = [:]
        for usage in try store.routeUsage(from: today, through: today) where appKeys.contains(usage.appKey) {
            appRoutes[usage.appKey, default: [:]][usage.route] = saturatingAdd(
                appRoutes[usage.appKey]?[usage.route] ?? 0,
                usage.totalBytes
            )
            reference[usage.route] = saturatingAdd(reference[usage.route] ?? 0, usage.totalBytes)
        }
        let routeSplit = RouteSplit(
            usages: appRecords.map { (totalBytes(for: $0), appRoutes[$0.appKey] ?? [:]) },
            reference: reference
        )
        if newRecords != records { records = newRecords }
        if routeSplit != todayRouteSplit { todayRouteSplit = routeSplit }
        return newRecords
    }

    /// 菜单栏面板的 60 分钟小图只需要分钟总量，一次分钟桶查询即可。
    private func loadMenuBarHourTimeline(from store: UsageStore) throws {
        let end = Date()
        let start = UsageTimeRange.lastHour.startDate(
            relativeTo: end,
            calendar: Calendar.autoupdatingCurrent
        )
        let newTimeline = makeTimeline(from: try store.bucketTimeline(from: start, to: end))
        if newTimeline != menuBarHourTimeline { menuBarHourTimeline = newTimeline }
    }

    private static func dailyRecords(
        from summaries: [UsageBucketSummaryRecord]
    ) -> [DailyUsageRecord] {
        summaries.map {
            DailyUsageRecord(
                day: dayKey(for: $0.firstBucketStart),
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
    }

    private func loadRange(
        from store: UsageStore,
        cachedToday: [DailyUsageRecord]? = nil
    ) throws {
        let calendar = Calendar.autoupdatingCurrent
        let end = Date()
        let start = selectedRange.startDate(relativeTo: end, calendar: calendar)

        try loadRangeRoutes(from: store, start: start, end: end)
        if selectedRange.usesBucketSummary {
            let summaries = try store.bucketUsageSummary(from: start, to: end)
            dailyRangeRecords = []
            setRangeRecords(Self.dailyRecords(from: summaries))
            try loadBucketRangeBars(from: store, start: start, end: end, calendar: calendar)
            try loadActiveDetailTimeline(from: store, start: start, end: end)
            return
        }

        let daily: [DailyUsageRecord]
        if let cachedToday {
            daily = cachedToday
        } else {
            daily = try store.dailyUsage(
                from: Self.dayKey(for: start),
                through: Self.dayKey(for: end)
            )
        }
        dailyRangeRecords = daily
        setRangeRecords(aggregateRecords(daily))
        if selectedRange == .today {
            try loadBucketRangeBars(from: store, start: start, end: end, calendar: calendar)
        } else {
            let usage = daily.filter { $0.category != .proxyTransport }
            setRangeBars(
                makeBars(
                    totals: usage.compactMap { record in
                        Self.date(from: record.day).map {
                            ($0, record.downloadBytes, record.uploadBytes)
                        }
                    },
                    appBytes: usage.compactMap { record in
                        Self.date(from: record.day).map {
                            ($0, record.appKey, totalBytes(for: record))
                        }
                    },
                    calendar: calendar
                )
            )
        }
        try loadActiveDetailTimeline(from: store, start: start, end: end)
    }

    /// 路径只按日汇总；「最近 1 小时」退化为今天的拆分，界面会注明。
    private func loadRangeRoutes(from store: UsageStore, start: Date, end: Date) throws {
        var usage: [String: [TrafficRoute: Int64]] = [:]
        for record in try store.routeUsage(
            from: Self.dayKey(for: start),
            through: Self.dayKey(for: end)
        ) {
            usage[record.appKey, default: [:]][record.route] = saturatingAdd(
                usage[record.appKey]?[record.route] ?? 0,
                record.totalBytes
            )
        }
        if usage != rangeRouteUsage {
            rangeRouteUsage = usage
            var reference: [TrafficRoute: Int64] = [:]
            for routes in usage.values {
                for (route, bytes) in routes {
                    reference[route] = saturatingAdd(reference[route] ?? 0, bytes)
                }
            }
            rangeRouteReference = reference
        }
    }

    /// 「最近 1 小时」与「今天」的柱子来自分钟桶。头部应用按 15 分钟槽查询再并入
    /// 本地小时：槽按 Unix 纪元对齐，15 分钟是所有时区偏移的公约数，并入后不会跨小时；
    /// 直接按分钟逐应用读取一整天会返回数万行。
    private func loadBucketRangeBars(
        from store: UsageStore,
        start: Date,
        end: Date,
        calendar: Calendar
    ) throws {
        let slotSeconds: Int64 = selectedRange == .lastHour ? 60 : 15 * 60
        let timeline = try store.bucketTimeline(from: start, to: end)
        let appSlots = try store.bucketTimelineByApp(
            from: start,
            to: end,
            slotSeconds: slotSeconds
        )
        setRangeBars(
            makeBars(
                totals: timeline.map { ($0.bucketStart, $0.downloadBytes, $0.uploadBytes) },
                appBytes: appSlots.map {
                    ($0.slotStart, $0.appKey, saturatingAdd($0.downloadBytes, $0.uploadBytes))
                },
                calendar: calendar
            )
        )
    }

    /// 按 `selectedRange.chartUnit` 把总量与逐应用流量并入柱子；只产出有数据的时段。
    private func makeBars(
        totals: [(start: Date, download: Int64, upload: Int64)],
        appBytes: [(start: Date, appKey: String, bytes: Int64)],
        calendar: Calendar
    ) -> [UsageChartBar] {
        let unit = selectedRange.chartUnit
        func slot(for date: Date) -> DateInterval {
            calendar.dateInterval(of: unit, for: date) ?? DateInterval(start: date, duration: 60)
        }

        var slots: [Date: DateInterval] = [:]
        var slotTotals: [Date: UsageTotals] = [:]
        for item in totals {
            let interval = slot(for: item.start)
            slots[interval.start] = interval
            let existing = slotTotals[interval.start] ?? UsageTotals(downloadBytes: 0, uploadBytes: 0)
            slotTotals[interval.start] = UsageTotals(
                downloadBytes: saturatingAdd(existing.downloadBytes, item.download),
                uploadBytes: saturatingAdd(existing.uploadBytes, item.upload)
            )
        }

        var slotApps: [Date: [String: Int64]] = [:]
        for item in appBytes {
            let start = slot(for: item.start).start
            slotApps[start, default: [:]][item.appKey, default: 0] = saturatingAdd(
                slotApps[start]?[item.appKey] ?? 0,
                item.bytes
            )
        }

        var names: [String: String] = [:]
        for record in rangeRecords {
            names[record.appKey] = record.displayName
        }

        return slotTotals.keys.sorted().compactMap { start in
            guard let interval = slots[start], let value = slotTotals[start] else { return nil }
            let top = slotApps[start]?.max {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            }
            return UsageChartBar(
                start: interval.start,
                end: interval.end,
                downloadBytes: value.downloadBytes,
                uploadBytes: value.uploadBytes,
                topAppName: top.flatMap { names[$0.key] },
                topAppBytes: top?.value ?? 0
            )
        }
    }

    private func refreshDetailTimeline(for appKey: String) {
        guard let store else {
            detailTimeline = []
            return
        }
        let calendar = Calendar.autoupdatingCurrent
        let end = Date()
        let start = selectedRange.startDate(relativeTo: end, calendar: calendar)
        do {
            try loadDetailTimeline(for: appKey, from: store, start: start, end: end)
        } catch {
            lastError = "读取应用趋势失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    private func loadActiveDetailTimeline(
        from store: UsageStore,
        start: Date,
        end: Date
    ) throws {
        guard let activeDetailAppKey else { return }
        try loadDetailTimeline(
            for: activeDetailAppKey,
            from: store,
            start: start,
            end: end
        )
    }

    private func loadDetailTimeline(
        for appKey: String,
        from store: UsageStore,
        start: Date,
        end: Date
    ) throws {
        guard rangeRecords.first(where: { $0.appKey == appKey })?.category != .proxyTransport else {
            detailTimeline = []
            return
        }
        if selectedRange.usesFineGrainedTimeline {
            detailTimeline = makeTimeline(
                from: try store.bucketTimeline(
                    from: start,
                    to: end,
                    appKey: appKey,
                    excludingProxyTransport: false
                )
            )
        } else {
            detailTimeline = makeTimeline(
                from: dailyRangeRecords.filter {
                    $0.appKey == appKey && $0.category != .proxyTransport
                }
            )
        }
    }

    /// `@Published` 赋值一律触发 objectWillChange 与全树失效，即使内容一字未变
    /// （夜间无流量时很常见）。这两个 setter 用 Equatable 短路掉无意义的重绘。
    private func setRangeRecords(_ newValue: [DailyUsageRecord]) {
        guard newValue != rangeRecords else { return }
        rangeRecords = newValue
    }

    private func setRangeBars(_ newValue: [UsageChartBar]) {
        guard newValue != rangeBars else { return }
        rangeBars = newValue
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

    private func makeTimeline(from records: [UsageTimelineRecord]) -> [UsageTimelinePoint] {
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

    private static func sampleDate(for rawValue: String) -> Date {
        NettopSampleClock.date(for: rawValue)
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
