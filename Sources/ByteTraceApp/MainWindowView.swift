import AppKit
import Charts
import ByteTraceCore
import SwiftUI

/// 主窗口单页：顶部统计卡与趋势图，下面按应用 / 系统进程 / 代理传输分组列出全部记录，
/// 点击一行在右侧详情栏查看该应用，不离开列表。
struct MainWindowView: View {
    @ObservedObject var model: ByteTraceViewModel
    @Environment(\.openWindow) private var openWindow

    @State private var searchText = ""
    @State private var expandedSections: Set<MainWindowSection> = [.applications]
    @State private var selectedAppKey: String?
    @State private var isInspectorPresented = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        summaryCards
                        TrendChartCard(
                            bars: model.rangeBars,
                            range: model.selectedRange
                        )
                        if visibleSections.isEmpty {
                            emptyCard("没有匹配“\(searchText)”的项目")
                        }
                        ForEach(visibleSections) { section in
                            sectionView(section)
                                .id(section)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                .onAppear {
                    // 首次打开时等布局完成再滚动，否则 scrollTo 找不到目标。
                    Task { @MainActor in handlePendingRequests(scrollProxy) }
                }
                .onChange(of: model.requestedMainWindowSection) { _, section in
                    if section != nil { handlePendingRequests(scrollProxy) }
                }
                .onChange(of: model.pendingAppDetailKey) { _, key in
                    if key != nil { handlePendingRequests(scrollProxy) }
                }
            }
            .navigationTitle("ByteTrace")
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
                    Button {
                        openWindow(id: "settings")
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .help("设置")
                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Label("详情", systemImage: "sidebar.trailing")
                    }
                    .help(isInspectorPresented ? "隐藏详情栏" : "显示详情栏")
                }
            }
            .inspector(isPresented: $isInspectorPresented) {
                Group {
                    if let selectedAppKey {
                        AppDetailView(appKey: selectedAppKey, model: model)
                            .id(selectedAppKey)
                    } else {
                        Text("在列表中选择一项查看详情")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
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
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 780)
        .onAppear {
            ByteTraceAppDelegate.windowDidAppear()
            model.beginObservingUsage(.mainOverview)
        }
        .onDisappear {
            model.endObservingUsage(.mainOverview)
            ByteTraceAppDelegate.windowDidDisappear()
        }
    }

    // MARK: - 分组

    private var visibleSections: [MainWindowSection] {
        MainWindowSection.allCases.filter { section in
            if section == .system, !model.showsSystemProcesses { return false }
            // 应用组始终显示，没有流量时给出空状态；其余分组没有记录就隐藏。
            if section == .applications, searchText.isEmpty { return true }
            return !records(in: section).isEmpty
        }
    }

    private func records(in section: MainWindowSection) -> [DailyUsageRecord] {
        let records = model.rangeRecords.filter { section.includes($0.category) }
        guard !searchText.isEmpty else { return records }
        return records.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    /// 搜索时所有分组都展开，避免匹配项藏在收起的分组里。
    private func expansion(of section: MainWindowSection) -> Binding<Bool> {
        Binding(
            get: { !searchText.isEmpty || expandedSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedSections.insert(section)
                } else {
                    expandedSections.remove(section)
                }
            }
        )
    }

    private func sectionView(_ section: MainWindowSection) -> some View {
        let records = records(in: section)
        return CollapsibleUsageSection(
            title: section.title,
            count: records.count,
            symbolName: section.symbolName,
            tint: section == .proxy ? TrafficColor.proxy : .secondary,
            isExpanded: expansion(of: section),
            detail: sectionDetail(section, records: records)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if section == .proxy, searchText.isEmpty,
                   let estimate = model.proxyTransportEstimate(
                       proxyBytes: model.selectedRangeProxyTotals.totalBytes
                   ) {
                    RouteSplitCard(
                        title: "代理外层流量去向（估算）",
                        split: estimate,
                        note: "按应用侧直连 / 代理的字节比例估算，不计入应用总量。",
                        showsProxyShare: false
                    )
                }
                if records.isEmpty {
                    emptyCard("当前时间范围内暂无应用流量")
                } else {
                    UsageTable(
                        records: records,
                        // 占比的分母：代理传输用代理总量，其余用不含代理的总量。
                        shareBase: section == .proxy
                            ? model.selectedRangeProxyTotals.totalBytes
                            : model.selectedRangeTotals.totalBytes,
                        selectedAppKey: selectedAppKey,
                        onSelect: selectApp,
                        // 路径只有日粒度，「最近 1 小时」逐行比例没有意义，整列不显示。
                        showsProxyColumn: section != .proxy && !model.routeBreakdownUsesToday,
                        proxyShare: { record in
                            let split = model.routeSplit(for: [record])
                            return split.isRepresentative ? split.proxyFraction : nil
                        },
                        subtitle: model.subtitle(for:)
                    )
                    .cardSurface()
                }
            }
        }
    }

    /// 分组标题右侧：合计，应用与系统进程再加代理占比（样本不足时不显示）。
    private func sectionDetail(_ section: MainWindowSection, records: [DailyUsageRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let total = records.reduce(Int64(0)) { partial, record in
            let result = partial.addingReportingOverflow(UsageTableRow.totalBytes(of: record))
            return result.overflow ? Int64.max : result.partialValue
        }
        var parts = ["合计 \(ByteTraceViewModel.formatBytes(total))"]
        if section == .proxy {
            parts.append("不计入总量")
        } else if searchText.isEmpty {
            let split = model.routeSplit(for: records)
            if split.isRepresentative {
                let percent = split.proxyFraction.formatted(.percent.precision(.fractionLength(1)))
                parts.append(model.routeBreakdownUsesToday ? "代理约 \(percent)" : "代理 \(percent)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func emptyCard(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cardSurface()
    }

    // MARK: - 选择与菜单栏跳转

    private func selectApp(_ appKey: String) {
        selectedAppKey = appKey
        isInspectorPresented = true
    }

    /// 处理菜单栏发来的「展开某分组」「打开某应用详情」请求，处理后置回 nil，同一请求可以再次触发。
    private func handlePendingRequests(_ scrollProxy: ScrollViewProxy) {
        if let appKey = model.pendingAppDetailKey {
            model.pendingAppDetailKey = nil
            model.requestedMainWindowSection = nil
            searchText = ""
            selectApp(appKey)
            guard let record = model.rangeRecords.first(where: { $0.appKey == appKey }),
                  let section = MainWindowSection.allCases.first(where: { $0.includes(record.category) })
            else { return }
            expandedSections.insert(section)
            withAnimation(.smooth) {
                scrollProxy.scrollTo(appKey, anchor: .center)
            }
        } else if let section = model.requestedMainWindowSection {
            model.requestedMainWindowSection = nil
            searchText = ""
            expandedSections.insert(section)
            withAnimation(.smooth) {
                scrollProxy.scrollTo(section, anchor: .top)
            }
        }
    }

    // MARK: - 工具栏与状态

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

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.status.tint)
                    .frame(width: 7, height: 7)
                Text(model.status.title)
                    .font(.caption.weight(.medium))
                Text(model.lastError ?? model.status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.lastError ?? model.status.detail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 7)
        }
        .background(.bar)
    }

    /// 总量 | 代理流量 | 直连。当前范围没有任何路径记录时，后两张换成上行 / 下行。
    /// 代理内核的外层收发（含规则直连）只在「代理传输」分组展示，不放在这里，避免和代理流量混淆。
    private var summaryCards: some View {
        let totals = model.selectedRangeTotals
        let split = model.routeSplit(for: model.rangeRecords)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            spacing: 12
        ) {
            SummaryCard(
                title: "总量",
                swatch: nil,
                value: totals.totalBytes,
                caption: directionCaption(upload: totals.uploadBytes, download: totals.downloadBytes)
            )
            if split.hasKnownRoute {
                routeSummaryCards(split: split, usesToday: model.routeBreakdownUsesToday)
            } else {
                SummaryCard(
                    title: "上行",
                    swatch: TrafficColor.upload,
                    value: totals.uploadBytes,
                    caption: shareCaption(totals.uploadBytes, of: totals.totalBytes)
                )
                SummaryCard(
                    title: "下行",
                    swatch: TrafficColor.download,
                    value: totals.downloadBytes,
                    caption: shareCaption(totals.downloadBytes, of: totals.totalBytes)
                )
            }
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

private extension MainWindowSection {
    var symbolName: String {
        switch self {
        case .applications: return "macwindow"
        case .system: return "terminal"
        case .proxy: return "arrow.triangle.branch"
        }
    }

    /// 应用组包含无法识别的进程；各组互斥，合起来覆盖全部分类。
    func includes(_ category: AppCategory) -> Bool {
        switch self {
        case .applications: return category == .userApp || category == .unclassified
        case .system: return category == .systemProcess
        case .proxy: return category == .proxyTransport
        }
    }
}

/// 代理流量与直连两张统计卡，概览与应用详情共用；口径与菜单栏「代理流量」一致。
@MainActor
@ViewBuilder
private func routeSummaryCards(split: RouteSplit, usesToday: Bool) -> some View {
    let help = RouteSplitCard.help(for: split)
    SummaryCard(
        title: "代理流量",
        swatch: RouteColor.proxy,
        value: split.proxyBytes,
        caption: split.unknownBytes > 0
            ? "另有 \(ByteTraceViewModel.formatBytes(split.unknownBytes)) 出口未知"
            : routeCaption(split.proxyBytes, in: split, usesToday: usesToday),
        help: help
    )
    SummaryCard(
        title: "直连",
        swatch: RouteColor.direct,
        value: split.directBytes,
        caption: routeCaption(split.directBytes, in: split, usesToday: usesToday),
        help: help
    )
}

/// 覆盖完整时给占比；大部分流量没有路径记录时不给比例，改为说明未区分的量。
@MainActor
private func routeCaption(_ bytes: Int64, in split: RouteSplit, usesToday: Bool) -> String {
    let percent = split.fraction(of: bytes).formatted(.percent.precision(.fractionLength(1)))
    if usesToday { return "按今天的比例估算 · \(percent)" }
    if !split.isPartial { return "占 \(percent)" }
    if split.isRepresentative { return "已区分部分的 \(percent)" }
    return "\(ByteTraceViewModel.formatBytes(split.unattributedBytes)) 未区分（统计启用前）"
}

@MainActor
private func directionCaption(upload: Int64, download: Int64) -> String {
    "↑ \(ByteTraceViewModel.formatBytes(upload))　↓ \(ByteTraceViewModel.formatBytes(download))"
}

@MainActor
private func shareCaption(_ value: Int64, of total: Int64) -> String {
    guard total > 0 else { return "占 0%" }
    let fraction = Double(value) / Double(total)
    return "占 \(fraction.formatted(.percent.precision(.fractionLength(1))))"
}

private struct SummaryCard: View {
    let title: String
    let swatch: Color?
    let value: Int64
    let caption: String
    var help: String?

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
        .help(help ?? "")
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
                legend(color: TrafficColor.upload, title: "上行")
                legend(color: TrafficColor.download, title: "下行")
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
                .frame(height: 160)
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
        .frame(height: 160)
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
            Text("↑ \(ByteTraceViewModel.formatBytes(bar.uploadBytes))　↓ \(ByteTraceViewModel.formatBytes(bar.downloadBytes))")
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

/// 应用、代理传输、系统进程共用的表格：应用 | 上行 | 下行 | 合计 | 代理 | 占比。
private struct UsageTable: View {
    let records: [DailyUsageRecord]
    let shareBase: Int64
    /// 详情栏正在展示的行，高亮显示。
    var selectedAppKey: String?
    var onSelect: (String) -> Void = { _ in }
    var showsProxyColumn = false
    /// 经代理节点转发的流量占比；没有足够的路径记录时为 nil。
    var proxyShare: (DailyUsageRecord) -> Double? = { _ in nil }
    var subtitle: (DailyUsageRecord) -> String? = { _ in nil }

    private static let numberColumnWidth: CGFloat = 84
    private static let proxyColumnWidth: CGFloat = 52
    private static let shareColumnWidth: CGFloat = 120

    var body: some View {
        let duplicateNames = ByteTraceViewModel.duplicateDisplayNames(in: records)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("名称")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("上行")
                    .frame(width: Self.numberColumnWidth, alignment: .trailing)
                Text("下行")
                    .frame(width: Self.numberColumnWidth, alignment: .trailing)
                Text("合计")
                    .frame(width: Self.numberColumnWidth, alignment: .trailing)
                if showsProxyColumn {
                    Text("代理")
                        .frame(width: Self.proxyColumnWidth, alignment: .trailing)
                        .help("代理流量（经机场节点转发）占该应用流量的比例；规则直连不算。")
                }
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
                    Button {
                        onSelect(record.appKey)
                    } label: {
                        UsageTableRow(
                            record: record,
                            share: share(of: record),
                            numberColumnWidth: Self.numberColumnWidth,
                            shareColumnWidth: Self.shareColumnWidth,
                            proxyColumnWidth: showsProxyColumn ? Self.proxyColumnWidth : nil,
                            showsPathHint: duplicateNames.contains(record.displayName),
                            proxyShare: showsProxyColumn ? proxyShare(record) : nil,
                            subtitle: subtitle(record)
                        )
                    }
                    .buttonStyle(.plain)
                    .background(
                        record.appKey == selectedAppKey ? Color.accentColor.opacity(0.12) : Color.clear
                    )
                    .interactiveHoverHighlight(cornerRadius: 0, opacity: 0.04)
                    .pointingHandCursor()
                    .id(record.appKey)
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
    /// nil 时不显示代理列。
    var proxyColumnWidth: CGFloat?
    var showsPathHint: Bool = false
    /// 经代理节点转发的流量占比；无路径数据或不足 1% 时显示「—」。
    var proxyShare: Double?
    /// 系统进程用途说明或命令行进程的启动者。
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                AppIconView(record: record, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayName)
                        .lineLimit(1)
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
            Text(ByteTraceViewModel.formatBytes(record.uploadBytes))
                .foregroundStyle(.secondary)
                .frame(width: numberColumnWidth, alignment: .trailing)
            Text(ByteTraceViewModel.formatBytes(record.downloadBytes))
                .foregroundStyle(.secondary)
                .frame(width: numberColumnWidth, alignment: .trailing)
            Text(ByteTraceViewModel.formatBytes(Self.totalBytes(of: record)))
                .fontWeight(.semibold)
                .frame(width: numberColumnWidth, alignment: .trailing)

            if let proxyColumnWidth {
                Group {
                    if let proxyShare, proxyShare >= 0.01 {
                        Text(proxyShare.formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(RouteColor.proxy)
                    } else {
                        Text("—")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: proxyColumnWidth, alignment: .trailing)
            }

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

/// 主窗口右侧详情栏的内容。
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
                    appTimeline
                } else {
                    Text("当前时间范围内没有这个应用的统计数据")
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
            }
            .padding(16)
        }
        .onAppear {
            model.beginObservingAppDetail(appKey)
        }
        .onDisappear {
            model.endObservingAppDetail(appKey)
        }
    }

    private func appHeader(_ record: DailyUsageRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(record: record, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if let subtitle = model.detailSubtitle(for: record) {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if record.bundlePath == nil, let path = record.executablePath {
                    Text(ByteTraceViewModel.abbreviatedPath(path))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(model.selectedRange.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// 合计 | 代理 | 直连，详情栏较窄，纵向排列；代理传输或没有足够的路径记录时，后两张换成上行 / 下行。
    private func appStats(_ record: DailyUsageRecord) -> some View {
        let total = totalBytes(for: record)
        let split = record.category == .proxyTransport ? RouteSplit.empty : model.routeSplit(for: [record])
        return VStack(spacing: 8) {
            SummaryCard(
                title: "合计",
                swatch: nil,
                value: total,
                caption: directionCaption(upload: record.uploadBytes, download: record.downloadBytes)
            )
            if split.hasKnownRoute {
                routeSummaryCards(split: split, usesToday: model.routeBreakdownUsesToday)
            } else {
                SummaryCard(
                    title: "上行",
                    swatch: TrafficColor.upload,
                    value: record.uploadBytes,
                    caption: shareCaption(record.uploadBytes, of: total)
                )
                SummaryCard(
                    title: "下行",
                    swatch: TrafficColor.download,
                    value: record.downloadBytes,
                    caption: shareCaption(record.downloadBytes, of: total)
                )
            }
        }
    }

    private var appTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("趋势")
                    .font(.headline)
                Spacer()
                timelineLegend(color: TrafficColor.upload, title: "上行")
                timelineLegend(color: TrafficColor.download, title: "下行")
            }

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
                        y: .value("字节", point.downloadBytes)
                    )
                    .foregroundStyle(TrafficColor.download)

                    BarMark(
                        x: .value("时间", point.start),
                        y: .value("字节", point.uploadBytes)
                    )
                    .foregroundStyle(TrafficColor.upload)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        if let bytes = value.as(Int64.self) {
                            AxisValueLabel(ByteTraceViewModel.formatBytes(bytes))
                        }
                    }
                }
                .frame(height: 180)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .cardSurface()
    }

    private func timelineLegend(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func totalBytes(for record: DailyUsageRecord) -> Int64 {
        let result = record.downloadBytes.addingReportingOverflow(record.uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}
