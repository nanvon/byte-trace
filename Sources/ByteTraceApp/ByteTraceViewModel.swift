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

enum UsageTimeRange: String, CaseIterable, Identifiable {
    case today
    case thisWeek
    case thisMonth
    case lastMonth
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .today: return "今日"
        case .thisWeek: return "本周"
        case .thisMonth: return "本月"
        case .lastMonth: return "上月"
        case .all: return "全部"
        }
    }

    var usesFineGrainedTimeline: Bool { self == .today }

    /// 日汇总使用包含末日的日期范围；分钟桶与导出使用实际起止时间。
    func window(relativeTo now: Date, calendar: Calendar, earliestDate: Date? = nil) -> UsageRangeWindow {
        let today = calendar.startOfDay(for: now)
        let dayEnd = calendar.dateInterval(of: .day, for: now)?.end ?? now
        let month = calendar.dateInterval(of: .month, for: now)
        let start: Date
        let end: Date
        let lastDay: Date
        let chartEnd: Date
        switch self {
        case .today:
            start = today
            end = now
            lastDay = today
            chartEnd = dayEnd
        case .thisWeek:
            let week = calendar.dateInterval(of: .weekOfYear, for: now)
            start = week?.start ?? today
            end = now
            lastDay = today
            chartEnd = week?.end ?? dayEnd
        case .thisMonth:
            start = month?.start ?? today
            end = now
            lastDay = today
            chartEnd = month?.end ?? dayEnd
        case .lastMonth:
            end = month?.start ?? today
            start = calendar.date(byAdding: .month, value: -1, to: end) ?? end
            lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? start
            chartEnd = end
        case .all:
            start = min(earliestDate.map { calendar.startOfDay(for: $0) } ?? today, today)
            end = now
            lastDay = today
            chartEnd = dayEnd
        }

        let chartUnit: Calendar.Component
        if self == .today {
            chartUnit = .hour
        } else if self == .all {
            let days = calendar.dateComponents([.day], from: start, to: chartEnd).day ?? 0
            let months = calendar.dateComponents([.month], from: start, to: chartEnd).month ?? 0
            chartUnit = days <= 62 ? .day : (months < 36 ? .month : .year)
        } else {
            chartUnit = .day
        }
        return UsageRangeWindow(
            start: start, end: end, lastDay: lastDay, chartEnd: chartEnd, chartUnit: chartUnit
        )
    }
}

/// 本次查询共用的日期边界和趋势粒度，避免图表与导出各自重新计算时间。
struct UsageRangeWindow: Equatable {
    let start: Date
    let end: Date
    let lastDay: Date
    let chartEnd: Date
    let chartUnit: Calendar.Component

    var chartUnitTitle: String {
        switch chartUnit {
        case .hour: return "每小时"
        case .month: return "每月"
        case .year: return "每年"
        default: return "每天"
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

/// 宿主下的一个程序；`programKey` 为空表示应用本身。
struct ProgramSlot: Hashable {
    let appKey: String
    let programKey: String
}

/// 宿主展开后程序排行里的一行。
struct HostProgramShare: Identifiable, Equatable {
    let programKey: String
    let name: String
    let iconRecord: DailyUsageRecord
    let uploadBytes: Int64
    let downloadBytes: Int64
    let bytes: Int64
    /// 系统进程的中文用途（如「系统软件更新下载」）；其他程序为空。
    let description: String?

    var id: String { programKey }
    var isApplicationItself: Bool { programKey.isEmpty }
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
            // 路径拆分限制在该应用的总量内。
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
    @Published private var diagnosticError: String?
    @Published private var usageWriteError: String?
    private(set) var lastError: String? {
        get { usageWriteError ?? diagnosticError }
        set { diagnosticError = newValue }
    }
    /// 数据库损坏后已隔离重建的提示；持久化到用户点「知道了」为止（`lastError` 会在 start() 清空，不能承载它）。
    @Published private(set) var storageNotice: String?
    /// 菜单栏「全部应用」请求主窗口列出全部应用并滚动到列表；主窗口处理后置回 false。
    @Published var requestsMainWindowAppList = false
    /// 从菜单栏点击某个应用后，主窗口据此选中该行并打开详情栏；处理后置回 nil。
    @Published var pendingAppDetailKey: String?
    /// 菜单栏齿轮或 ⌘, 请求打开主窗口的设置页；处理后置回 false。
    @Published var requestsMainWindowSettings = false
    @Published var selectedRange: UsageTimeRange = .today {
        didSet {
            guard oldValue != selectedRange else { return }
            if observedUsageSurfaces.contains(.mainOverview) {
                refreshOverview()
            }
        }
    }
    @Published private(set) var rangeWindow = UsageTimeRange.today.window(
        relativeTo: Date(), calendar: Calendar.autoupdatingCurrent
    )
    /// 菜单栏面板的最近 1 小时分钟趋势（不含代理传输）。
    @Published private(set) var menuBarHourTimeline: [UsageTimelinePoint] = []
    @Published private(set) var rangeRecords: [DailyUsageRecord] = []
    /// 当前时间范围内每个宿主下每个程序的流量（每个宿主 + 程序一行）。
    @Published private(set) var rangePrograms: [ProgramUsageRecord] = []
    /// 当前时间范围内每个宿主 + 程序按路径汇总的字节数（日粒度）。
    @Published private(set) var rangeProgramRoutes: [ProgramSlot: [TrafficRoute: Int64]] = [:]
    @Published private(set) var rangeBars: [UsageChartBar] = []
    @Published private(set) var detailTimeline: [UsageTimelinePoint] = []
    @Published private(set) var detailDomains: [ByteTraceExportDocument.DomainUsage] = []
    @Published private(set) var bucketStats: UsageBucketStats?
    /// 当前时间范围内各应用按路径汇总的字节数（日粒度；「最近 1 小时」按今天统计）。
    @Published private(set) var rangeRouteUsage: [String: [TrafficRoute: Int64]] = [:]
    /// `rangeRouteUsage` 按路径合并后的总量，作为出口未知流量的分摊参照。
    private var rangeRouteReference: [TrafficRoute: Int64] = [:]
    private var dailyRangeRecords: [DailyUsageRecord] = []
    /// 今天每个宿主下的程序，按流量排序，供菜单栏副标题使用。
    private var todayProgramsByHost: [String: [ProgramUsageRecord]] = [:]
    private var rangeProgramsByHost: [String: [ProgramUsageRecord]] = [:]

    private var activeDetailAppKey: String?
    @Published private(set) var launchAtLoginEnabled: Bool
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
            if !readsMihomoConnections { supplementalResidualTracker.discardDomains() }
            updateMihomoPolling()
        }
    }
    @Published var recordsDomains: Bool {
        didSet {
            guard oldValue != recordsDomains else { return }
            UserDefaults.standard.set(recordsDomains, forKey: Self.recordsDomainsKey)
            mihomoRequestID = nil
            if !recordsDomains {
                mihomoRouteTracker.discardDomains()
                supplementalResidualTracker.discardDomains()
            }
        }
    }
    @Published private(set) var mihomoStatus: MihomoConnectionStatus = .idle
    let databaseURL: URL

    private static let usageRetentionPolicyKey = "ByteTrace.usageRetentionPolicy"
    private static let detectedProxyExecutablesKey = "ByteTrace.detectedProxyExecutables"
    private static let readsMihomoConnectionsKey = "ByteTrace.readsMihomoConnections"
    private static let recordsDomainsKey = "ByteTrace.recordsDomains"
    private static let storageRecoveryNoticeKey = "ByteTrace.storageRecoveryNotice"
    private static let storageRecoveryFileKey = "ByteTrace.storageRecoveryFile"
    /// 只在最近有经代理流量时轮询，空闲时不访问控制器。
    private static let mihomoActiveWindow: TimeInterval = 30
    private static let mihomoPollInterval: TimeInterval = 1
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
    /// nettop 进程名 → 最近一次解析到的宿主与程序，落库后供重启时预填名称缓存。
    private var recordedProcessNames: [String: ProcessNameAttribution] = [:]
    private var pendingProcessNames: [String: ProcessNameAttribution] = [:]
    private var mihomoController: MihomoController?
    private var lastSuccessfulMihomoController: MihomoController?
    private var mihomoTimer: Timer?
    private var mihomoRequestID: UUID?
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

        let storedRetentionPolicy = UserDefaults.standard.string(
            forKey: Self.usageRetentionPolicyKey
        )
        _usageRetentionPolicy = Published(
            initialValue: UsageRetentionPolicy(rawValue: storedRetentionPolicy ?? "") ?? .ninetyDays
        )
        _readsMihomoConnections = Published(
            initialValue: UserDefaults.standard.object(forKey: Self.readsMihomoConnectionsKey) as? Bool ?? true
        )
        _recordsDomains = Published(initialValue: UserDefaults.standard.bool(forKey: Self.recordsDomainsKey))
        detectedProxyExecutables = UserDefaults.standard.stringArray(
            forKey: Self.detectedProxyExecutablesKey
        ) ?? []
        for path in detectedProxyExecutables {
            attributionCache.registerDetectedProxy(executablePath: path)
        }

        var storageError: String?
        let opened = Self.openStore(at: databaseURL)
        let quarantinedName = opened.quarantinedURL?.lastPathComponent
        if let quarantined = opened.quarantinedURL {
            let notice = opened.store == nil
                ? "数据库已损坏，旧文件已另存为 \(quarantined.lastPathComponent)。"
                : "数据库已损坏，旧文件已另存为 \(quarantined.lastPathComponent)，统计从现在重新开始。"
            UserDefaults.standard.set(notice, forKey: Self.storageRecoveryNoticeKey)
            UserDefaults.standard.set(quarantined.path, forKey: Self.storageRecoveryFileKey)
        }
        if let store = opened.store {
            self.store = store
            aggregator = UsageAggregator(store: store)
            if let remembered = try? store.rememberedProcessAttributions() {
                attributionCache.seed(remembered)
                recordedProcessNames = Dictionary(
                    remembered.map {
                        ($0.processName, ProcessNameAttribution(appKey: $0.appKey, programKey: $0.program?.key ?? ""))
                    },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        } else {
            store = nil
            aggregator = nil
            storageError = opened.error
        }
        _storageNotice = Published(
            initialValue: UserDefaults.standard.string(forKey: Self.storageRecoveryNoticeKey)
        )

        super.init()
        if let storageError {
            lastError = storageError
            status = .failed(storageError)
        }
        if let quarantinedName {
            recordCollectorEvent(kind: "database_quarantined", details: quarantinedName)
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

    /// 应用列表：系统进程与命令行工具一并列出；代理传输不计入总量，不在列表里展示。
    var applicationRecords: [DailyUsageRecord] {
        records.filter { $0.category != .proxyTransport }
    }

    /// 主窗口当前时间范围的应用列表，口径同 `applicationRecords`。
    var rangeApplicationRecords: [DailyUsageRecord] {
        rangeRecords.filter { $0.category != .proxyTransport }
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
        detailDomains = []
        refreshAppDetail()
    }

    func endObservingAppDetail(_ appKey: String) {
        guard activeDetailAppKey == appKey else { return }
        activeDetailAppKey = nil
        detailTimeline = []
        detailDomains = []
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
        beginCollection()
    }

    private func beginCollection() {
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
        stopCollection()
        finishStoppingIfPossible()
    }

    private func stopCollection() {
        let wasCollecting = wantsCollection
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
        if collector.state != .stopped {
            collector.stop()
        }
        if loopbackCollector.state != .stopped {
            loopbackCollector.stop()
        }
        proxyEndpointMonitor.stop()
        cancelInstanceLockWait()
        updateMihomoPolling()
        if status != .incompatible { status = .stopped }
        if wasCollecting { recordCollectorEvent(kind: "collector_stopped") }
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

    func prepareForTermination() throws {
        stopCollection()
        try finishStoppingCollection()
    }

    private func finishStoppingIfPossible() {
        do {
            try finishStoppingCollection()
            refreshIfNeeded(force: true)
        } catch {
            // 保留锁和定时器，写入恢复后再交给等待中的实例。
        }
    }

    private func finishStoppingCollection() throws {
        try saveUsage()
        saveProcessNames()
        flushTimer?.invalidate()
        flushTimer = nil
        instanceLock.release()
        externalGapRecovery.reset()
    }

    func refresh() {
        guard let store else {
            records = []
            todayRouteSplit = .empty
            menuBarHourTimeline = []
            rangeRecords = []
            rangeBars = []
            detailTimeline = []
            detailDomains = []
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
            detailDomains = []
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

    func routeSplit(for records: [DailyUsageRecord]) -> RouteSplit {
        RouteSplit(
            usages: records.filter { $0.category != .proxyTransport }.map {
                (totalBytes(for: $0), rangeRouteUsage[$0.appKey] ?? [:])
            },
            reference: rangeRouteReference
        )
    }

    func timeline(for appKey: String) -> [UsageTimelinePoint] {
        activeDetailAppKey == appKey ? detailTimeline : []
    }

    /// 宿主下的程序排行（含应用本身），按流量排序。
    func programs(forHost record: DailyUsageRecord) -> [HostProgramShare] {
        (rangeProgramsByHost[record.appKey] ?? []).map { program in
            let iconRecord = program.programKey.isEmpty ? record : Self.iconRecord(for: program)
            return HostProgramShare(
                programKey: program.programKey,
                name: program.programKey.isEmpty ? "应用本身" : program.programName ?? program.programKey,
                iconRecord: iconRecord,
                uploadBytes: program.uploadBytes,
                downloadBytes: program.downloadBytes,
                bytes: program.totalBytes,
                description: iconRecord.category == .userApp
                    ? nil
                    : SystemProcessDescriptions.description(forExecutablePath: iconRecord.executablePath)
            )
        }
    }

    /// 宿主下某个程序的直连 / 代理拆分。
    func routeSplit(forHost appKey: String, programKey: String, totalBytes: Int64) -> RouteSplit {
        RouteSplit(
            usages: [(totalBytes, rangeProgramRoutes[ProgramSlot(appKey: appKey, programKey: programKey)] ?? [:])],
            reference: rangeRouteReference
        )
    }

    /// 程序没有应用包，用它的可执行文件找图标（命令行工具显示终端，Claude Code 显示 Claude）。
    static func iconRecord(for program: ProgramUsageRecord) -> DailyUsageRecord {
        DailyUsageRecord(
            day: program.day,
            appKey: program.programKey,
            displayName: program.programName ?? program.programKey,
            category: program.programCategory ?? .unclassified,
            bundleID: program.programKey.hasPrefix("bundle:")
                ? String(program.programKey.dropFirst("bundle:".count))
                : nil,
            bundlePath: nil,
            executablePath: program.programExecutablePath,
            downloadBytes: program.downloadBytes,
            uploadBytes: program.uploadBytes,
            sampleCount: 0
        )
    }

    func clearAllData() throws {
        guard let store, let aggregator else {
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: lastError ?? "本地数据库不可用。"
            ])
        }
        let alreadyHeld = instanceLock.isHeld
        guard instanceLock.tryAcquire() else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: "无法取得数据目录锁，请关闭正在使用同一数据库的其他 ByteTrace 实例后重试。"
            ])
        }
        let shouldRestart = isStarted || isLoopbackStarted
        if shouldRestart { stopCollection() }
        defer {
            if shouldRestart { beginCollection() }
            if !alreadyHeld { instanceLock.release() }
        }
        do {
            try store.clearAll()
            aggregator.discardPending()
            usageWriteError = nil
            if wantsCollection { externalGapRecovery.arm() }
            supplementalResidualTracker.reset()
            pendingProcessNames = [:]
            recordedProcessNames = [:]
            records = []
            todayRouteSplit = .empty
            menuBarHourTimeline = []
            rangeRecords = []
            rangePrograms = []
            rangeProgramRoutes = [:]
            todayProgramsByHost = [:]
            rangeProgramsByHost = [:]
            rangeRouteUsage = [:]
            rangeRouteReference = [:]
            rangeBars = []
            bucketStats = UsageBucketStats(
                bucketCount: 0,
                earliestBucket: nil,
                latestBucket: nil
            )
            dailyRangeRecords = []
            rangeWindow = selectedRange.window(relativeTo: Date(), calendar: Calendar.autoupdatingCurrent)
            detailTimeline = []
            detailDomains = []
            activeDetailAppKey = nil
            lastRetentionCleanupDay = nil
            lastError = nil
        } catch {
            lastError = "清空统计失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
            throw error
        }
    }

    func exportCurrentRange(to url: URL) throws {
        var domainUsage: [ByteTraceExportDocument.DomainUsage] = []
        if let store {
            let today = selectedRange == .today ? try loadToday(from: store) : nil
            try loadRange(from: store, cachedToday: today)
            let records = try store.domainUsage(
                from: selectedRange == .all ? "0001-01-01" : Self.dayKey(for: rangeWindow.start),
                through: Self.dayKey(for: rangeWindow.lastDay)
            )
            domainUsage = summarizeDomains(records)
        }
        let exportedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let document = ByteTraceExportDocument(
            formatVersion: 6,
            accountingVersion: UsageStore.accountingVersion,
            product: "ByteTrace",
            exportedAt: exportedAt,
            range: ByteTraceExportDocument.Range(
                id: selectedRange.rawValue,
                title: selectedRange.title,
                start: rangeWindow.start,
                end: rangeWindow.end
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
            },
            programUsage: rangePrograms.map { program in
                ByteTraceExportDocument.ProgramUsage(
                    appKey: program.appKey,
                    programKey: program.programKey,
                    displayName: program.programKey.isEmpty
                        ? rangeRecords.first { $0.appKey == program.appKey }?.displayName ?? program.appKey
                        : program.programName ?? program.programKey,
                    executablePath: program.programExecutablePath,
                    downloadBytes: program.downloadBytes,
                    uploadBytes: program.uploadBytes,
                    totalBytes: program.totalBytes,
                    routeBytes: Dictionary(
                        uniqueKeysWithValues: (rangeProgramRoutes[
                            ProgramSlot(appKey: program.appKey, programKey: program.programKey)
                        ] ?? [:]).map { ($0.key.rawValue, $0.value) }
                    )
                )
            },
            domainUsage: domainUsage
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

    /// 菜单栏列表副标题（今天）：系统进程的中文用途说明，宿主里运行过的程序。
    func subtitle(for record: DailyUsageRecord) -> String? {
        hostSubtitle(for: record, programs: todayProgramsByHost[record.appKey] ?? [])
    }

    /// 主窗口列表副标题（当前时间范围），口径同 `subtitle(for:)`。
    func rangeSubtitle(for record: DailyUsageRecord) -> String? {
        hostSubtitle(for: record, programs: rangeProgramsByHost[record.appKey] ?? [])
    }

    private func hostSubtitle(for record: DailyUsageRecord, programs: [ProgramUsageRecord]) -> String? {
        var parts: [String] = []
        if record.category != .userApp, !VirtualHost.isVirtual(record.appKey),
           let description = SystemProcessDescriptions.description(forExecutablePath: record.executablePath) {
            parts.append(description)
        }
        let names = programs.filter { !$0.programKey.isEmpty }.map { $0.programName ?? $0.programKey }
        if !names.isEmpty {
            let shown = names.prefix(2).joined(separator: "、")
            parts.append(names.count > 2 ? "含 \(shown) 等 \(names.count) 个程序" : "含 \(shown)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 详情里的说明：虚拟宿主的含义，系统应用的用途。
    func detailSubtitle(for record: DailyUsageRecord) -> String? {
        switch record.appKey {
        case VirtualHost.systemKey:
            return "系统目录下的守护进程与服务"
        case VirtualHost.otherKey:
            return "不在任何应用里运行的命令行工具：由 launchd 直接启动的后台程序、按应用区分程序之前记录的命令行流量，以及解析前就退出、无法识别来源的进程"
        default:
            guard record.category != .userApp else { return nil }
            return SystemProcessDescriptions.description(forExecutablePath: record.executablePath)
        }
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
        // 在同一次主线程回调里处理尾帧，也避免退出事件跨到下一次启动后才处理。
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handle(event, lane: lane)
            }
            return
        }
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
        flushNow(forceRefresh: true)
        guard wantsCollection else { return }

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
        if lane == .external, status == .incompatible { return }
        if lane == .loopback, !loopbackCollectorCompatible { return }
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
                let route: (NettopDelta) -> RouteResolution = { [weak self] in
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
                ingest(routed.delta, route: routed.route, domain: routed.domain)
            }

        case .malformedRow:
            break

        case .schemaChanged:
            break

        case let .incompatibleSchema(missingColumns):
            let message = "CSV 格式不兼容，缺少：\(missingColumns.joined(separator: "、"))"
            if lane == .external {
                guard wantsCollection else { return }
                status = .incompatible
                lastError = message
                stop()
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
    private func supplementalRoute(for delta: NettopDelta) -> RouteResolution {
        guard readsMihomoConnections else { return .proxied }
        let resolution = mihomoRouteTracker.resolution(forLocalEndpoint: delta.localEndpoint) ?? .proxied
        return RouteResolution(route: resolution.route, domain: recordsDomains ? resolution.domain : nil)
    }

    // MARK: - mihomo 连接表

    private func updateMihomoPolling() {
        guard readsMihomoConnections, wantsCollection else {
            mihomoTimer?.invalidate()
            mihomoTimer = nil
            mihomoController = nil
            lastSuccessfulMihomoController = nil
            mihomoRequestID = nil
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
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        mihomoTimer = timer
        mihomoTimerFired()
    }

    private var hasRecentSupplementalTraffic: Bool {
        guard let lastSupplementalTrafficAt else { return false }
        return Date().timeIntervalSince(lastSupplementalTrafficAt) <= Self.mihomoActiveWindow
    }

    private func mihomoTimerFired() {
        guard readsMihomoConnections, wantsCollection, mihomoRequestID == nil else { return }
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
            guard let discovered = discoverMihomoController() else {
                mihomoStatus = .searching
                return
            }
            if discovered != lastSuccessfulMihomoController {
                mihomoRouteTracker.removeAll()
            }
            mihomoController = discovered
        }
        guard let controller = mihomoController else { return }

        let requestID = UUID()
        mihomoRequestID = requestID
        let client = mihomoClient
        let includeDomains = recordsDomains
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<MihomoConnectionsSnapshot, Error>
            do {
                let data = try await client.get("/connections", from: controller)
                result = .success(try MihomoConnectionsParser.parse(data, includeDomains: includeDomains))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.finishMihomoFetch(result, controller: controller, requestID: requestID)
            }
        }
    }

    private func finishMihomoFetch(
        _ result: Result<MihomoConnectionsSnapshot, Error>,
        controller: MihomoController,
        requestID: UUID
    ) {
        guard mihomoRequestID == requestID else { return }
        mihomoRequestID = nil
        guard readsMihomoConnections, wantsCollection, mihomoController == controller else { return }
        switch result {
        case let .success(snapshot):
            mihomoRouteTracker.update(with: snapshot)
            lastSuccessfulMihomoController = controller
            let count = snapshot.connections.count
            if mihomoStatus != .connected(connectionCount: count) {
                if case .connected = mihomoStatus {} else {
                    recordCollectorEvent(kind: "mihomo_connected")
                }
                mihomoStatus = .connected(connectionCount: count)
            }
        case let .failure(error):
            // 内核重启后地址可能变化：清掉控制器，下一轮按间隔重新发现。
            mihomoController = nil
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

    private func ingest(_ delta: NettopDelta, route: TrafficRoute, domain: String? = nil) {
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
        if identity.executablePath != nil || identity.bundlePath != nil,
           !attributed.nettopProcessName.isEmpty,
           attributed.category != .proxyTransport {
            let attribution = ProcessNameAttribution(
                appKey: attributed.appKey,
                programKey: attributed.program?.key ?? ""
            )
            if recordedProcessNames[attributed.nettopProcessName] != attribution {
                pendingProcessNames[attributed.nettopProcessName] = attribution
            }
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
                    route: attributed.category == .proxyTransport ? nil : route,
                    program: attributed.program,
                    domain: readsMihomoConnections && recordsDomains && attributed.category != .proxyTransport ? domain : nil
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
        guard wantsCollection else {
            finishStoppingIfPossible()
            return
        }
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
        flushNow(forceRefresh: true)
        guard wantsCollection else { return }
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
        do {
            try saveUsage()
        } catch {
            return
        }
        saveProcessNames()
        refreshIfNeeded(force: forceRefresh)
    }

    private func saveUsage() throws {
        do {
            _ = try aggregator?.flush()
        } catch {
            let message = "数据库写入失败：\(error.localizedDescription)"
            if usageWriteError != message {
                usageWriteError = message
                recordCollectorEvent(kind: "database_error", details: message)
            }
            throw error
        }
        if usageWriteError != nil { usageWriteError = nil }
    }

    private func saveProcessNames() {
        guard !pendingProcessNames.isEmpty, let store else { return }
        do {
            try store.recordProcessNames(pendingProcessNames)
            recordedProcessNames.merge(pendingProcessNames) { _, new in new }
            pendingProcessNames = [:]
        } catch {
            lastError = "进程归属缓存写入失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    /// 打开数据库。文件损坏时在持有数据目录锁的前提下改名保留旧文件并新建；
    /// 版本过新和其他错误（权限、磁盘满、被占用）不隔离。
    private static func openStore(
        at url: URL
    ) -> (store: UsageStore?, error: String?, quarantinedURL: URL?) {
        let firstError: Error
        do {
            return (try UsageStore(databaseURL: url), nil, nil)
        } catch {
            firstError = error
        }
        if UsageStore.isNewerSchema(firstError) {
            return (nil, "数据库由更新版本的 ByteTrace 创建，请升级应用后再使用。", nil)
        }
        guard UsageStore.isCorruption(firstError) else {
            return (nil, "无法打开本地数据库：\(firstError.localizedDescription)", nil)
        }
        // init 里还不能用 self.instanceLock，临时建一个同路径的锁，用完释放。
        let lock = DataDirectoryLock(url: DataDirectoryLock.defaultLockURL(bundleIdentifier: bundleIdentifier))
        guard lock.tryAcquire() else {
            return (nil, "数据库无法读取，另一个 ByteTrace 正在运行；请退出它之后重新打开。", nil)
        }
        defer { lock.release() }
        // 另一实例可能已在本实例等待加锁期间完成恢复，必须用锁内的结果判断。
        do {
            return (try UsageStore(databaseURL: url), nil, nil)
        } catch {
            if UsageStore.isNewerSchema(error) {
                return (nil, "数据库由更新版本的 ByteTrace 创建，请升级应用后再使用。", nil)
            }
            guard UsageStore.isCorruption(error) else {
                return (nil, "无法打开本地数据库：\(error.localizedDescription)", nil)
            }
        }
        let quarantined: URL
        do {
            quarantined = try UsageStore.quarantineDatabase(at: url)
        } catch {
            return (nil, "数据库已损坏，隔离失败：\(error.localizedDescription)", nil)
        }
        do {
            return (try UsageStore(databaseURL: url), nil, quarantined)
        } catch {
            return (nil, "旧数据库已另存为 \(quarantined.lastPathComponent)，重建失败：\(error.localizedDescription)", quarantined)
        }
    }

    func dismissStorageNotice() {
        storageNotice = nil
        UserDefaults.standard.removeObject(forKey: Self.storageRecoveryNoticeKey)
        UserDefaults.standard.removeObject(forKey: Self.storageRecoveryFileKey)
    }

    func revealQuarantinedDatabase() {
        let path = UserDefaults.standard.string(forKey: Self.storageRecoveryFileKey)
        if let path, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([databaseURL])
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
        todayPrograms = try store.programUsage(from: today, through: today)
        todayProgramsByHost = Self.programsByHost(todayPrograms)
        if newRecords != records { records = newRecords }
        if routeSplit != todayRouteSplit { todayRouteSplit = routeSplit }
        return newRecords
    }

    /// 最近一次 `loadToday` 读到的今天的程序流量（每个宿主 + 程序一行）。
    private var todayPrograms: [ProgramUsageRecord] = []

    private static func programsByHost(_ programs: [ProgramUsageRecord]) -> [String: [ProgramUsageRecord]] {
        Dictionary(grouping: programs, by: \.appKey).mapValues { rows in
            rows.sorted {
                $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.programKey < $1.programKey
            }
        }
    }

    /// 按宿主 + 程序合并多天的行；名称等取最近一天有值的。
    private static func aggregatePrograms(_ programs: [ProgramUsageRecord]) -> [ProgramUsageRecord] {
        var order: [ProgramSlot] = []
        var merged: [ProgramSlot: ProgramUsageRecord] = [:]
        for program in programs.sorted(by: { $0.day < $1.day }) {
            let slot = ProgramSlot(appKey: program.appKey, programKey: program.programKey)
            guard let existing = merged[slot] else {
                order.append(slot)
                merged[slot] = program
                continue
            }
            merged[slot] = ProgramUsageRecord(
                day: existing.day,
                appKey: program.appKey,
                programKey: program.programKey,
                programName: program.programName ?? existing.programName,
                programCategory: program.programCategory ?? existing.programCategory,
                programExecutablePath: program.programExecutablePath ?? existing.programExecutablePath,
                downloadBytes: saturating(existing.downloadBytes, program.downloadBytes),
                uploadBytes: saturating(existing.uploadBytes, program.uploadBytes)
            )
        }
        return order.compactMap { merged[$0] }
    }

    private static func saturating(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }

    /// 设置程序数据并按宿主分组，供应用详情与副标题使用。
    private func setRangePrograms(_ programs: [ProgramUsageRecord]) {
        let sorted = programs.sorted {
            $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.programIdentity < $1.programIdentity
        }
        rangeProgramsByHost = Self.programsByHost(sorted)
        if sorted != rangePrograms { rangePrograms = sorted }
    }

    /// 菜单栏面板的 60 分钟小图只需要分钟总量，一次分钟桶查询即可。
    private func loadMenuBarHourTimeline(from store: UsageStore) throws {
        let end = Date()
        let start = end.addingTimeInterval(-60 * 60)
        let newTimeline = makeTimeline(from: try store.bucketTimeline(from: start, to: end))
        if newTimeline != menuBarHourTimeline { menuBarHourTimeline = newTimeline }
    }

    private func loadRange(
        from store: UsageStore,
        cachedToday: [DailyUsageRecord]? = nil
    ) throws {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        var window = selectedRange.window(relativeTo: now, calendar: calendar)
        // 全部记录直接从日汇总查询；不能用可能已清理的分钟桶推导历史起点。
        let startDay = selectedRange == .all ? "0001-01-01" : Self.dayKey(for: window.start)
        let endDay = Self.dayKey(for: window.lastDay)
        let validTodayCache = cachedToday.flatMap { rows in
            selectedRange == .today && rows.allSatisfy { $0.day == endDay } ? rows : nil
        }
        let daily = try validTodayCache ?? store.dailyUsage(from: startDay, through: endDay)
        if selectedRange == .all {
            let firstDay = daily.lazy.map(\.day).min()
            window = selectedRange.window(
                relativeTo: now, calendar: calendar, earliestDate: firstDay.flatMap(Self.date(from:))
            )
        }
        let start = window.start
        let end = window.end
        if window != rangeWindow { rangeWindow = window }
        try loadRangeRoutes(from: store, startDay: startDay, endDay: endDay)
        dailyRangeRecords = daily
        setRangeRecords(aggregateRecords(daily))
        let dailyPrograms = try validTodayCache != nil
            ? todayPrograms
            : store.programUsage(from: startDay, through: endDay)
        setRangePrograms(Self.aggregatePrograms(dailyPrograms))
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
        try loadActiveDetail(from: store, startDay: startDay, endDay: endDay)
    }

    /// 路径与日汇总使用相同的首日、末日（均包含）。
    private func loadRangeRoutes(from store: UsageStore, startDay: String, endDay: String) throws {
        var usage: [String: [TrafficRoute: Int64]] = [:]
        for record in try store.routeUsage(
            from: startDay,
            through: endDay
        ) {
            usage[record.appKey, default: [:]][record.route] = saturatingAdd(
                usage[record.appKey]?[record.route] ?? 0,
                record.totalBytes
            )
        }
        var programRoutes: [ProgramSlot: [TrafficRoute: Int64]] = [:]
        for record in try store.programRouteUsage(
            from: startDay,
            through: endDay
        ) {
            let slot = ProgramSlot(appKey: record.appKey, programKey: record.programKey)
            programRoutes[slot, default: [:]][record.route] = saturatingAdd(
                programRoutes[slot]?[record.route] ?? 0,
                record.totalBytes
            )
        }
        if programRoutes != rangeProgramRoutes { rangeProgramRoutes = programRoutes }
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

    /// 「今日」的柱子来自分钟桶。头部应用按 15 分钟槽查询再并入
    /// 本地小时：槽按 Unix 纪元对齐，15 分钟是所有时区偏移的公约数，并入后不会跨小时；
    /// 直接按分钟逐应用读取一整天会返回数万行。
    private func loadBucketRangeBars(
        from store: UsageStore,
        start: Date,
        end: Date,
        calendar: Calendar
    ) throws {
        let slotSeconds: Int64 = 15 * 60
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

    /// 按当前时间范围的粒度合并总量与逐应用流量；只产出有数据的时段。
    private func makeBars(
        totals: [(start: Date, download: Int64, upload: Int64)],
        appBytes: [(start: Date, appKey: String, bytes: Int64)],
        calendar: Calendar
    ) -> [UsageChartBar] {
        let unit = rangeWindow.chartUnit
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

    private func refreshAppDetail() {
        guard let store else {
            detailTimeline = []
            detailDomains = []
            return
        }
        do {
            try loadActiveDetail(
                from: store,
                startDay: selectedRange == .all ? "0001-01-01" : Self.dayKey(for: rangeWindow.start),
                endDay: Self.dayKey(for: rangeWindow.lastDay)
            )
        } catch {
            lastError = "读取应用详情失败：\(error.localizedDescription)"
            recordCollectorEvent(kind: "database_error", details: lastError)
        }
    }

    private func loadActiveDetail(
        from store: UsageStore,
        startDay: String,
        endDay: String
    ) throws {
        guard let appKey = activeDetailAppKey else { return }
        try loadDetailTimeline(for: appKey, from: store, start: rangeWindow.start, end: rangeWindow.end)
        let records = try store.domainUsage(appKey: appKey, from: startDay, through: endDay)
        let domains = summarizeDomains(records)
        if detailDomains != domains { detailDomains = domains }
    }

    private func summarizeDomains(_ records: [DomainUsageRecord]) -> [ByteTraceExportDocument.DomainUsage] {
        struct Key: Hashable {
            let appKey: String
            let domain: String
        }
        struct Usage {
            var download: Int64 = 0
            var upload: Int64 = 0
            var routes: [String: Int64] = [:]
        }
        var grouped: [Key: Usage] = [:]
        for record in records {
            let key = Key(appKey: record.appKey, domain: record.domain)
            var usage = grouped[key] ?? Usage()
            usage.download = saturatingAdd(usage.download, record.downloadBytes)
            usage.upload = saturatingAdd(usage.upload, record.uploadBytes)
            usage.routes[record.route.rawValue] = saturatingAdd(
                usage.routes[record.route.rawValue, default: 0],
                saturatingAdd(record.downloadBytes, record.uploadBytes)
            )
            grouped[key] = usage
        }
        return grouped.map { key, usage in
            ByteTraceExportDocument.DomainUsage(
                appKey: key.appKey, domain: key.domain, downloadBytes: usage.download, uploadBytes: usage.upload,
                totalBytes: saturatingAdd(usage.download, usage.upload), routeBytes: usage.routes
            )
        }.sorted {
            if $0.appKey != $1.appKey { return $0.appKey < $1.appKey }
            if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
            return $0.domain < $1.domain
        }
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
