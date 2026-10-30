import AppKit
import Charts
import ByteTraceCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var model: ByteTraceViewModel
    @State private var selection: MainWindowPage = .overview
    /// 窗口打开时把键盘焦点交给侧边栏，否则 AppKit 会落到工具栏的折叠按钮上并画出蓝色焦点底。
    @FocusState private var isSidebarFocused: Bool
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("统计") {
                    sidebarLabel("概览", systemImage: "chart.xyaxis.line", page: .overview)
                        .tag(MainWindowPage.overview)
                    sidebarLabel("应用", systemImage: "macwindow", page: .applications)
                        .badge(count(of: .applications))
                        .tag(MainWindowPage.applications)
                    sidebarLabel("代理传输", systemImage: "arrow.triangle.branch", page: .proxy)
                        .badge(count(of: .proxy))
                        .tag(MainWindowPage.proxy)
                    if model.showsSystemProcesses {
                        sidebarLabel("系统进程", systemImage: "terminal", page: .system)
                            .badge(count(of: .system))
                            .tag(MainWindowPage.system)
                    }
                }
                Section {
                    sidebarLabel("设置", systemImage: "gearshape", page: .settings)
                        .tag(MainWindowPage.settings)
                }
            }
            .listStyle(.sidebar)
            .focused($isSidebarFocused)
            .defaultFocus($isSidebarFocused, true)
            .safeAreaInset(edge: .bottom) { statusBox }
            .navigationSplitViewColumnWidth(min: 190, ideal: 212)
            .navigationTitle("ByteTrace")
        } detail: {
            switch selection {
            case .settings:
                SettingsView(model: model)
            default:
                MainUsagePage(model: model, page: selection) {
                    selection = .applications
                }
                .id(selection)
            }
        }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 780)
        .onAppear {
            selection = model.requestedMainWindowPage
            ByteTraceAppDelegate.prepareMainWindow()
            NSApplication.shared.activate(ignoringOtherApps: true)
            if selection.showsUsage {
                model.beginObservingUsage(.mainOverview)
            }
        }
        .onDisappear {
            model.endObservingUsage(.mainOverview)
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        .onChange(of: selection) { oldPage, newPage in
            if oldPage.showsUsage, !newPage.showsUsage {
                model.endObservingUsage(.mainOverview)
            }
            if newPage.showsUsage {
                model.beginObservingUsage(.mainOverview)
            }
        }
        .onChange(of: model.requestedMainWindowPage) { _, page in
            selection = page
        }
    }

    private func sidebarLabel(_ title: String, systemImage: String, page: MainWindowPage) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(MainSidebarLabelStyle(isSelected: selection == page))
    }

    private func count(of page: MainWindowPage) -> Int {
        model.rangeRecords.filter(page.includes).count
    }

    private var statusBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.status.tint)
                    .frame(width: 7, height: 7)
                Text(model.status.title)
                    .font(.subheadline.weight(.medium))
            }
            Text(model.lastError ?? model.status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(10)
    }
}

private struct MainSidebarLabelStyle: LabelStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 12, weight: .regular))
                .imageScale(.medium)
                .symbolVariant(.none)
                .symbolRenderingMode(.monochrome)
                .frame(width: 14, height: 14)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
            configuration.title
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
    }
}

private extension MainWindowPage {
    var showsUsage: Bool {
        self != .settings
    }

    /// 各统计页展示的记录分类；概览页的表格只列应用。
    func includes(_ record: DailyUsageRecord) -> Bool {
        switch self {
        case .overview, .applications:
            return record.category == .userApp || record.category == .unclassified
        case .proxy:
            return record.category == .proxyTransport
        case .system:
            return record.category == .systemProcess
        case .settings:
            return false
        }
    }
}

private struct MainUsagePage: View {
    @ObservedObject var model: ByteTraceViewModel
    let page: MainWindowPage
    let onShowAllApplications: () -> Void

    @State private var searchText = ""
    @State private var path = NavigationPath()
    @State private var exportError: String?

    private let overviewRowLimit = 10

    private var pageRecords: [DailyUsageRecord] {
        let records = model.rangeRecords.filter(page.includes)
        guard !searchText.isEmpty else { return records }
        return records.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    /// 占比的分母：代理传输页用代理总量，其余用不含代理的总量。
    private var shareBase: Int64 {
        page == .proxy
            ? model.selectedRangeProxyTotals.totalBytes
            : model.selectedRangeTotals.totalBytes
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if page == .overview {
                        summaryCards
                        TrendChartCard(
                            bars: model.rangeBars,
                            range: model.selectedRange
                        )
                    }
                    routeSection
                    tableSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(page.title)
            .searchable(text: $searchText, placement: .toolbar, prompt: "按名称搜索")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    rangePicker
                    Button {
                        exportCurrentRange()
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .help("导出当前范围 JSON")
                }
            }
            .navigationDestination(for: String.self) { appKey in
                AppDetailView(appKey: appKey, model: model)
            }
            .onChange(of: model.pendingAppDetailKey) { _, newValue in
                guard let newValue else { return }
                path.append(newValue)
                model.pendingAppDetailKey = nil
            }
            .onAppear {
                if let key = model.pendingAppDetailKey {
                    path.append(key)
                    model.pendingAppDetailKey = nil
                }
            }
            .alert(
                "导出失败",
                isPresented: Binding(
                    get: { exportError != nil },
                    set: { if !$0 { exportError = nil } }
                )
            ) {
                Button("好") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    private var rangePicker: some View {
        Picker("时间范围", selection: $model.selectedRange) {
            ForEach(UsageTimeRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var summaryCards: some View {
        let totals = model.selectedRangeTotals
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4),
            spacing: 12
        ) {
            SummaryCard(
                title: "总量",
                swatch: nil,
                value: totals.totalBytes,
                caption: "不含代理传输"
            )
            SummaryCard(
                title: "下行",
                swatch: TrafficColor.download,
                value: totals.downloadBytes,
                caption: shareCaption(totals.downloadBytes, of: totals.totalBytes)
            )
            SummaryCard(
                title: "上行",
                swatch: TrafficColor.upload,
                value: totals.uploadBytes,
                caption: shareCaption(totals.uploadBytes, of: totals.totalBytes)
            )
            SummaryCard(
                title: "代理传输",
                swatch: TrafficColor.proxy,
                value: model.selectedRangeProxyTotals.totalBytes,
                caption: "单独展示，不计入总量"
            )
        }
    }

    private func shareCaption(_ value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "占 0%" }
        let fraction = Double(value) / Double(total)
        return "占 \(fraction.formatted(.percent.precision(.fractionLength(1))))"
    }

    /// 概览按全部非代理流量、应用页与系统页按本页记录拆分直连与经代理。
    @ViewBuilder
    private var routeSection: some View {
        if page == .proxy, searchText.isEmpty,
           let estimate = model.proxyTransportEstimate(
               proxyBytes: model.selectedRangeProxyTotals.totalBytes
           ) {
            RouteBreakdownCard(
                title: "代理外层流量去向（估算）",
                breakdown: estimate,
                footnote: "按 mihomo 连接表中应用侧「节点 / 规则直连」的字节比例估算代理内核外层连接的去向，仅供参考，不计入应用总量。",
                showsProxiedShare: false
            )
        } else if page != .proxy, searchText.isEmpty {
            let records = page == .overview
                ? model.rangeRecords
                : model.rangeRecords.filter(page.includes)
            let breakdown = model.routeBreakdown(for: records)
            if breakdown.hasKnownRoute {
                RouteBreakdownCard(
                    title: "流量路径",
                    breakdown: breakdown,
                    footnote: RouteBreakdownCard.footnote(usesToday: model.routeBreakdownUsesToday)
                )
            }
        }
    }

    @ViewBuilder
    private var tableSection: some View {
        let records = pageRecords
        let isTruncated = page == .overview && searchText.isEmpty && records.count > overviewRowLimit
        let visible = isTruncated ? Array(records.prefix(overviewRowLimit)) : records

        if records.isEmpty {
            Text(emptyMessage)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .cardSurface()
        } else {
            VStack(spacing: 0) {
                UsageTable(
                    records: visible,
                    shareBase: shareBase,
                    proxiedShare: { record in
                        guard page != .proxy, !model.routeBreakdownUsesToday else { return nil }
                        let breakdown = model.routeBreakdown(for: [record])
                        guard breakdown.hasKnownRoute else { return nil }
                        return breakdown.fraction(of: breakdown.proxiedBytes)
                    },
                    subtitle: model.subtitle(for:)
                )
                if isTruncated {
                    Divider()
                    Button("查看全部 \(records.count) 个应用", action: onShowAllApplications)
                        .buttonStyle(.link)
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .pointingHandCursor()
                }
            }
            .cardSurface()
        }
    }

    private var emptyMessage: String {
        if !searchText.isEmpty {
            return "没有匹配“\(searchText)”的项目"
        }
        switch page {
        case .proxy: return "当前时间范围内暂无代理传输流量"
        case .system: return "当前时间范围内暂无系统进程流量"
        default: return "当前时间范围内暂无应用流量"
        }
    }

    private func exportCurrentRange() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ByteTrace-\(model.selectedRange.rawValue).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try model.exportCurrentRange(to: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

private struct SummaryCard: View {
    let title: String
    let swatch: Color?
    let value: Int64
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(swatch)
                        .frame(width: 8, height: 8)
                }
                Text(title)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text(ByteTraceViewModel.formatBytes(value))
                .font(.system(size: 26, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(.smooth, value: value)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }
}

private struct TrendChartCard: View {
    let bars: [UsageChartBar]
    let range: UsageTimeRange

    @State private var hoveredBar: UsageChartBar?
    @State private var hoverX: CGFloat = 0

    private var calendar: Calendar { Calendar.autoupdatingCurrent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("流量趋势 · \(range.chartUnitTitle)")
                    .font(.headline)
                Spacer()
                legend(color: TrafficColor.download, title: "下行")
                legend(color: TrafficColor.upload, title: "上行")
            }

            if bars.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无时间粒度数据")
                        .font(.subheadline.weight(.medium))
                    Text("统计运行一段时间后会在这里显示趋势。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            } else {
                chart
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .cardSurface()
        .onChange(of: bars) { _, newBars in
            if let hoveredBar, !newBars.contains(where: { $0.start == hoveredBar.start }) {
                self.hoveredBar = nil
            }
        }
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var chart: some View {
        let now = Date()
        let domainStart = range.startDate(relativeTo: now, calendar: calendar)
        let domainEnd = max(range.chartEndDate(relativeTo: now, calendar: calendar), domainStart.addingTimeInterval(60))
        let unit = range.chartUnit
        return Chart(bars) { bar in
            BarMark(
                x: .value("时间", bar.start, unit: unit),
                y: .value("字节", bar.downloadBytes)
            )
            .foregroundStyle(TrafficColor.download.opacity(opacity(for: bar)))

            BarMark(
                x: .value("时间", bar.start, unit: unit),
                y: .value("字节", bar.uploadBytes)
            )
            .foregroundStyle(TrafficColor.upload.opacity(opacity(for: bar)))
        }
        .chartXScale(domain: domainStart...domainEnd)
        .chartXAxis {
            AxisMarks(values: .stride(by: axisStride.component, count: axisStride.count)) { _ in
                AxisGridLine()
                AxisValueLabel(format: axisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                if let bytes = value.as(Int64.self) {
                    AxisValueLabel(ByteTraceViewModel.formatBytes(bytes))
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHover(at: location, proxy: proxy, geometry: geometry)
                        case .ended:
                            hoveredBar = nil
                        }
                    }
            }
        }
        .overlay {
            GeometryReader { geometry in
                if let hoveredBar {
                    let bubbleWidth: CGFloat = 180
                    let clampedX = min(
                        max(hoverX, bubbleWidth / 2 + 4),
                        geometry.size.width - bubbleWidth / 2 - 4
                    )
                    hoverBubble(for: hoveredBar)
                        .frame(width: bubbleWidth, alignment: .leading)
                        .position(x: clampedX, y: 34)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 200)
    }

    private func opacity(for bar: UsageChartBar) -> Double {
        guard let hoveredBar else { return 1 }
        return hoveredBar.start == bar.start ? 1 : 0.4
    }

    private var axisStride: (component: Calendar.Component, count: Int) {
        switch range {
        case .lastHour: return (.minute, 15)
        case .today: return (.hour, 6)
        case .thisWeek: return (.day, 1)
        case .thisMonth: return (.day, 7)
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .lastHour: return .dateTime.hour().minute()
        case .today: return .dateTime.hour()
        case .thisWeek: return .dateTime.weekday(.abbreviated)
        case .thisMonth: return .dateTime.month(.defaultDigits).day()
        }
    }

    private func updateHover(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrameAnchor = proxy.plotFrame else { return }
        let plotFrame = geometry[plotFrameAnchor]
        let relativeX = location.x - plotFrame.origin.x
        guard let date = proxy.value(atX: relativeX, as: Date.self) else { return }
        let bar = bars.first { $0.start <= date && date < $0.end }
        if bar != hoveredBar { hoveredBar = bar }
        if let bar {
            let middle = bar.start.addingTimeInterval(bar.end.timeIntervalSince(bar.start) / 2)
            hoverX = (proxy.position(forX: middle) ?? relativeX) + plotFrame.origin.x
        }
    }

    private func hoverBubble(for bar: UsageChartBar) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(timeTitle(for: bar))
                .font(.caption.weight(.semibold))
            Text("↓ \(ByteTraceViewModel.formatBytes(bar.downloadBytes))　↑ \(ByteTraceViewModel.formatBytes(bar.uploadBytes))")
                .font(.caption)
            if let name = bar.topAppName, bar.totalBytes > 0, bar.topAppBytes > 0 {
                let share = min(1, Double(bar.topAppBytes) / Double(bar.totalBytes))
                Text("\(name) 占 \(share.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
    }

    private func timeTitle(for bar: UsageChartBar) -> String {
        switch range.chartUnit {
        case .minute:
            return bar.start.formatted(date: .omitted, time: .shortened)
        case .hour:
            let start = bar.start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
            let end = bar.end.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute())
            return "\(start) – \(end)"
        default:
            return bar.start.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated))
        }
    }
}

/// 应用、代理传输、系统进程共用的表格：应用 | 下行 | 上行 | 合计 | 占比。
private struct UsageTable: View {
    let records: [DailyUsageRecord]
    let shareBase: Int64
    var proxiedShare: (DailyUsageRecord) -> Double? = { _ in nil }
    var subtitle: (DailyUsageRecord) -> String? = { _ in nil }

    private static let numberColumnWidth: CGFloat = 90
    private static let shareColumnWidth: CGFloat = 150

    var body: some View {
        let duplicateNames = ByteTraceViewModel.duplicateDisplayNames(in: records)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("名称")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("下行")
                    .frame(width: Self.numberColumnWidth, alignment: .trailing)
                Text("上行")
                    .frame(width: Self.numberColumnWidth, alignment: .trailing)
                Text("合计")
                    .frame(width: Self.numberColumnWidth, alignment: .trailing)
                Text("占比")
                    .frame(width: Self.shareColumnWidth, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)

            Divider()

            LazyVStack(spacing: 0) {
                ForEach(records, id: \.appKey) { record in
                    NavigationLink(value: record.appKey) {
                        UsageTableRow(
                            record: record,
                            share: share(of: record),
                            numberColumnWidth: Self.numberColumnWidth,
                            shareColumnWidth: Self.shareColumnWidth,
                            showsPathHint: duplicateNames.contains(record.displayName),
                            proxiedShare: proxiedShare(record),
                            subtitle: subtitle(record)
                        )
                    }
                    .buttonStyle(.plain)
                    .interactiveHoverHighlight(cornerRadius: 0, opacity: 0.04)
                    .pointingHandCursor()
                    if record.appKey != records.last?.appKey {
                        Divider()
                            .padding(.leading, 18)
                    }
                }
            }
        }
        // 只在行集合本身变化（排名变动、增删应用）时做布局动画，字节数变化不触发。
        .animation(.smooth, value: records.map(\.appKey))
    }

    private func share(of record: DailyUsageRecord) -> Double {
        guard shareBase > 0 else { return 0 }
        return min(1, Double(UsageTableRow.totalBytes(of: record)) / Double(shareBase))
    }
}

private struct UsageTableRow: View {
    let record: DailyUsageRecord
    let share: Double
    let numberColumnWidth: CGFloat
    let shareColumnWidth: CGFloat
    var showsPathHint: Bool = false
    /// 经代理流量占该行的比例；无路径数据或占比不足 1% 时为 nil，不显示标签。
    var proxiedShare: Double?
    /// 系统进程用途说明或命令行进程的启动者。
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                AppIconView(record: record, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(record.displayName)
                            .lineLimit(1)
                        if let proxiedShare, proxiedShare >= 0.01 {
                            Text(proxiedShare >= 0.995
                                 ? "经代理"
                                 : "经代理 \(proxiedShare.formatted(.percent.precision(.fractionLength(0))))")
                                .font(.caption2)
                                .foregroundStyle(RouteColor.color(for: .proxied))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(RouteColor.color(for: .proxied).opacity(0.12))
                                )
                                .fixedSize()
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(subtitle)
                    }
                    if showsPathHint, let path = record.bundlePath ?? record.executablePath {
                        Text(ByteTraceViewModel.abbreviatedPath(path))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 这里刻意不加 .contentTransition(.numericText())：列表每 10 秒刷新一次且
            // 数值必然变化，逐行数字滚动动画会让整个可见列表持续重绘，是渲染开销的主要来源。
            // 顶部统计卡数量固定，仍保留动画作为视觉焦点。
            Text(ByteTraceViewModel.formatBytes(record.downloadBytes))
                .foregroundStyle(.secondary)
                .frame(width: numberColumnWidth, alignment: .trailing)
            Text(ByteTraceViewModel.formatBytes(record.uploadBytes))
                .foregroundStyle(.secondary)
                .frame(width: numberColumnWidth, alignment: .trailing)
            Text(ByteTraceViewModel.formatBytes(Self.totalBytes(of: record)))
                .fontWeight(.semibold)
                .frame(width: numberColumnWidth, alignment: .trailing)

            HStack(spacing: 8) {
                UsageShareBar(fraction: share, height: 5)
                Text(share.formatted(.percent.precision(.fractionLength(1))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(width: shareColumnWidth)
        }
        .monospacedDigit()
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    static func totalBytes(of record: DailyUsageRecord) -> Int64 {
        let result = record.downloadBytes.addingReportingOverflow(record.uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}

private struct AppDetailView: View {
    let appKey: String
    @ObservedObject var model: ByteTraceViewModel

    private var record: DailyUsageRecord? {
        model.rangeRecords.first { $0.appKey == appKey }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let record {
                    appHeader(record)
                    appStats(record)
                    if record.category != .proxyTransport {
                        let breakdown = model.routeBreakdown(for: [record])
                        if breakdown.hasKnownRoute {
                            RouteBreakdownCard(
                                title: "流量路径",
                                breakdown: breakdown,
                                footnote: RouteBreakdownCard.footnote(
                                    usesToday: model.routeBreakdownUsesToday
                                )
                            )
                        }
                    }
                    appTimeline
                } else {
                    Text("当前时间范围内没有这个应用的统计数据")
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(record?.displayName ?? "应用详情")
        .onAppear {
            model.beginObservingAppDetail(appKey)
        }
        .onDisappear {
            model.endObservingAppDetail(appKey)
        }
    }

    private func appHeader(_ record: DailyUsageRecord) -> some View {
        HStack(spacing: 14) {
            AppIconView(record: record, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.title2.weight(.semibold))
                if let subtitle = model.subtitle(for: record) {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if record.bundlePath == nil, let path = record.executablePath {
                    Text(ByteTraceViewModel.abbreviatedPath(path))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                Text(model.selectedRange.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func appStats(_ record: DailyUsageRecord) -> some View {
        let total = totalBytes(for: record)
        return HStack(spacing: 12) {
            SummaryCard(
                title: "合计",
                swatch: nil,
                value: total,
                caption: model.selectedRange.title
            )
            SummaryCard(
                title: "下行",
                swatch: TrafficColor.download,
                value: record.downloadBytes,
                caption: shareCaption(record.downloadBytes, of: total)
            )
            SummaryCard(
                title: "上行",
                swatch: TrafficColor.upload,
                value: record.uploadBytes,
                caption: shareCaption(record.uploadBytes, of: total)
            )
        }
    }

    private func shareCaption(_ value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "占 0%" }
        let fraction = Double(value) / Double(total)
        return "占 \(fraction.formatted(.percent.precision(.fractionLength(1))))"
    }

    private var appTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("应用趋势")
                .font(.headline)

            let points = model.timeline(for: appKey)
            if points.isEmpty {
                Text("当前应用暂无可用的时间粒度数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 30)
            } else {
                Chart(points) { point in
                    BarMark(
                        x: .value("时间", point.start),
                        y: .value("总量", point.totalBytes)
                    )
                    .foregroundStyle(TrafficColor.download)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        if let bytes = value.as(Int64.self) {
                            AxisValueLabel(ByteTraceViewModel.formatBytes(bytes))
                        }
                    }
                }
                .frame(height: 240)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .cardSurface()
    }

    private func totalBytes(for record: DailyUsageRecord) -> Int64 {
        let result = record.downloadBytes.addingReportingOverflow(record.uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}
