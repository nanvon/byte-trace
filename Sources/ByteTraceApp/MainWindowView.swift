import AppKit
import Charts
import ByteTraceCore
import SwiftUI

/// 主窗口统计页：顶部总量与趋势并排；下方是全部应用（含系统进程与命令行工具）的单一列表，
/// 点击一行在行下展开该应用的详情。代理传输不计入总量，不在列表里展示。
/// 设置是同一窗口里推入的独立页面，从右下角悬浮按钮、菜单栏齿轮或 ⌘, 进入；
/// 悬浮按钮在设置页变成返回，进出都在同一位置。
struct MainWindowView: View {
    @ObservedObject var model: ByteTraceViewModel

    @State private var searchText = ""
    /// 行下展开详情的应用，同一时间只展开一行。
    @State private var expandedAppKey: String?
    /// 已点开「显示其余」；否则只列前几行。
    @State private var listsAllApplications = false
    @State private var isShowingSettings = false

    /// 收起时列出的行数。
    private static let collapsedRowLimit = 12
    private static let appListID = "appList"
    /// 悬浮按钮距窗口右下角的距离；底部留出状态栏的高度，主页与设置页位置一致。
    private static let floatingButtonInset = EdgeInsets(top: 0, leading: 0, bottom: 44, trailing: 24)
    /// 滚动内容底部留白，最后一行不被悬浮按钮挡住。
    private static let floatingButtonClearance: CGFloat = 64

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        OverviewHeader(model: model)
                        appList
                            .id(Self.appListID)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 1320)
                    .frame(maxWidth: .infinity)
                }
                .contentMargins(.bottom, Self.floatingButtonClearance, for: .scrollContent)
                .background(Color(nsColor: .windowBackgroundColor))
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                .onAppear {
                    // 首次打开时等布局完成再滚动，否则 scrollTo 找不到目标。
                    Task { @MainActor in handlePendingRequests(scrollProxy) }
                }
                .onChange(of: model.requestsMainWindowAppList) { _, requested in
                    if requested { handlePendingRequests(scrollProxy) }
                }
                .onChange(of: model.pendingAppDetailKey) { _, key in
                    if key != nil { handlePendingRequests(scrollProxy) }
                }
                .onChange(of: model.requestsMainWindowSettings) { _, requested in
                    if requested { handlePendingRequests(scrollProxy) }
                }
            }
            .navigationTitle("ByteTrace")
            .navigationDestination(isPresented: $isShowingSettings) {
                SettingsView(model: model)
                    .contentMargins(.bottom, Self.floatingButtonClearance, for: .scrollContent)
                    // 返回统一用右下角悬浮按钮或 Esc，不再显示系统返回按钮。
                    .navigationBarBackButtonHidden(true)
                    .onExitCommand { isShowingSettings = false }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "按名称搜索")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    rangePicker
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            FloatingSettingsButton(isShowingSettings: $isShowingSettings)
                .padding(Self.floatingButtonInset)
        }
        .frame(minWidth: 760, idealWidth: 1100, minHeight: 600, idealHeight: 800)
        .onChange(of: searchText) { _, _ in
            // 展开的行被搜索过滤掉后不再保留展开状态。
            if let expandedAppKey,
               !filteredRecords.contains(where: { $0.appKey == expandedAppKey }) {
                self.expandedAppKey = nil
            }
        }
        .onAppear {
            ByteTraceAppDelegate.windowDidAppear()
            model.beginObservingUsage(.mainOverview)
        }
        .onDisappear {
            model.endObservingUsage(.mainOverview)
            ByteTraceAppDelegate.windowDidDisappear()
        }
    }

    // MARK: - 应用列表

    private var filteredRecords: [DailyUsageRecord] {
        let records = model.rangeApplicationRecords
        guard !searchText.isEmpty else { return records }
        return records.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    /// 只多出一两行时直接全部列出，不显示「显示其余 1 个」。
    private func listsAllRows(count: Int) -> Bool {
        !searchText.isEmpty
            || listsAllApplications
            || count <= Self.collapsedRowLimit + 2
    }

    private var appList: some View {
        let records = filteredRecords
        // 排名按搜索前的完整列表计算，搜索时不变。
        let ranked = model.rangeApplicationRecords
        let listsAll = listsAllRows(count: records.count)
        let visible = listsAll ? records : Array(records.prefix(Self.collapsedRowLimit))
        let duplicateNames = ByteTraceViewModel.duplicateDisplayNames(in: ranked)
        let shareBase = model.selectedRangeTotals.totalBytes

        return VStack(alignment: .leading, spacing: 4) {
            listHeader(records: records)

            if records.isEmpty {
                emptyMessage(searchText.isEmpty ? "当前时间范围内暂无应用流量" : "没有匹配“\(searchText)”的应用")
                    .padding(.top, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(visible, id: \.appKey) { record in
                        rowWithDetail(
                            record,
                            share: share(of: record, base: shareBase),
                            note: rowNote(for: record, duplicateNames: duplicateNames),
                            rank: (ranked.firstIndex { $0.appKey == record.appKey } ?? 0) + 1,
                            rankCount: ranked.count,
                            showsDivider: record.appKey != visible.last?.appKey
                        )
                        .id(record.appKey)
                    }
                }
                // 只在行集合本身变化（排名变动、增删应用）时做布局动画，字节数变化不触发。
                .animation(.smooth, value: visible.map(\.appKey))

                if !listsAll {
                    listToggle("显示其余 \(records.count - visible.count) 个", systemImage: "chevron.down") {
                        listsAllApplications = true
                    }
                } else if searchText.isEmpty,
                          listsAllApplications,
                          records.count > Self.collapsedRowLimit + 2 {
                    listToggle("收起", systemImage: "chevron.up") {
                        listsAllApplications = false
                        if let expandedAppKey,
                           !records.prefix(Self.collapsedRowLimit).contains(where: { $0.appKey == expandedAppKey }),
                           records.contains(where: { $0.appKey == expandedAppKey }) {
                            self.expandedAppKey = nil
                        }
                    }
                }
            }
        }
    }

    private func listHeader(records: [DailyUsageRecord]) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("应用")
                    .font(.headline)
                Text("\(records.count)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if let detail = listDetail(records: records) {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(height: 1)
        }
    }

    /// 列表标题右侧：合计，再加代理占比（样本不足时不显示）。
    private func listDetail(records: [DailyUsageRecord]) -> String? {
        guard !records.isEmpty else { return nil }
        let total = records.reduce(Int64(0)) { saturatingAdd($0, totalBytes(of: $1)) }
        var parts = [ByteTraceViewModel.formatBytes(total)]
        if searchText.isEmpty {
            let split = model.routeSplit(for: records)
            if split.isRepresentative {
                let percent = split.proxyFraction.formatted(.percent.precision(.fractionLength(0)))
                parts.append(model.routeBreakdownUsesToday ? "代理约 \(percent)" : "代理 \(percent)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func rowWithDetail(
        _ record: DailyUsageRecord,
        share: Double,
        note: String?,
        rank: Int,
        rankCount: Int,
        showsDivider: Bool
    ) -> some View {
        let isExpanded = expandedAppKey == record.appKey
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpansion(of: record.appKey)
            } label: {
                UsageRow(record: record, share: share, note: note, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)
            .interactiveHoverHighlight(cornerRadius: 8, opacity: isExpanded ? 0 : 0.045)
            .pointingHandCursor()
            .focusable(false)
            .accessibilityHint(isExpanded ? "收起详情" : "展开详情")

            if isExpanded {
                AppDetailPanel(record: record, rank: rank, rankCount: rankCount, model: model)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.045 : 0))
        )
        .overlay(alignment: .bottom) {
            if showsDivider, !isExpanded {
                Divider()
                    .padding(.leading, 40)
            }
        }
        .padding(.vertical, isExpanded ? 4 : 0)
    }

    /// 行内名称后的浅色说明：系统进程用途或启动者；同名不同路径时补上路径。
    private func rowNote(for record: DailyUsageRecord, duplicateNames: Set<String>) -> String? {
        if let subtitle = model.subtitle(for: record) { return subtitle }
        if duplicateNames.contains(record.displayName),
           let path = record.bundlePath ?? record.executablePath {
            return ByteTraceViewModel.abbreviatedPath(path)
        }
        return nil
    }

    private func share(of record: DailyUsageRecord, base: Int64) -> Double {
        guard base > 0 else { return 0 }
        return min(1, Double(totalBytes(of: record)) / Double(base))
    }

    private func listToggle(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) { action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                Text(title)
            }
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .interactiveHoverHighlight(cornerRadius: 6, opacity: 0.05)
        .pointingHandCursor()
        .focusable(false)
        .padding(.top, 2)
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
    }

    // MARK: - 展开与菜单栏跳转

    private func toggleExpansion(of appKey: String) {
        withAnimation(.smooth(duration: 0.22)) {
            expandedAppKey = expandedAppKey == appKey ? nil : appKey
        }
    }

    /// 处理菜单栏发来的「列出全部应用」「打开某应用详情」「打开设置」请求，处理后复位，同一请求可以再次触发。
    private func handlePendingRequests(_ scrollProxy: ScrollViewProxy) {
        if model.requestsMainWindowSettings {
            model.requestsMainWindowSettings = false
            model.pendingAppDetailKey = nil
            model.requestsMainWindowAppList = false
            isShowingSettings = true
        } else if let appKey = model.pendingAppDetailKey {
            isShowingSettings = false
            model.pendingAppDetailKey = nil
            model.requestsMainWindowAppList = false
            searchText = ""
            let records = model.rangeApplicationRecords
            guard let index = records.firstIndex(where: { $0.appKey == appKey }) else { return }
            // 目标行在「显示其余」里时先全部列出。
            if index >= Self.collapsedRowLimit {
                listsAllApplications = true
            }
            expandedAppKey = appKey
            Task { @MainActor in
                withAnimation(.smooth) {
                    scrollProxy.scrollTo(appKey, anchor: .center)
                }
            }
        } else if model.requestsMainWindowAppList {
            isShowingSettings = false
            model.requestsMainWindowAppList = false
            searchText = ""
            listsAllApplications = true
            Task { @MainActor in
                withAnimation(.smooth) {
                    scrollProxy.scrollTo(Self.appListID, anchor: .top)
                }
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
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 7)
        }
        .background(.bar)
    }
}

/// 右下角悬浮的液态玻璃圆形按钮：主页显示齿轮进入设置，设置页显示返回。
private struct FloatingSettingsButton: View {
    @Binding var isShowingSettings: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                isShowingSettings.toggle()
            }
        } label: {
            Image(systemName: isShowingSettings ? "chevron.backward" : "gearshape")
                .font(.system(size: 17, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // 不参与键盘焦点：否则窗口一打开它就成为首个焦点，带出蓝色焦点环。
        .focusable(false)
        .glassEffect(.regular.interactive(), in: Circle())
        .pointingHandCursor()
        .help(isShowingSettings ? "返回" : "设置（⌘,）")
        .accessibilityLabel(isShowingSettings ? "返回" : "设置")
    }
}

private extension UsageTimeRange {
    var axisStride: (component: Calendar.Component, count: Int) {
        switch self {
        case .lastHour: return (.minute, 15)
        case .today: return (.hour, 6)
        case .thisWeek: return (.day, 1)
        case .thisMonth: return (.day, 7)
        }
    }

    var axisFormat: Date.FormatStyle {
        switch self {
        case .lastHour: return .dateTime.hour().minute()
        case .today: return .dateTime.hour()
        case .thisWeek: return .dateTime.weekday(.abbreviated)
        case .thisMonth: return .dateTime.month(.defaultDigits).day()
        }
    }

    func chartDomain(now: Date, calendar: Calendar) -> ClosedRange<Date> {
        let start = startDate(relativeTo: now, calendar: calendar)
        let end = max(chartEndDate(relativeTo: now, calendar: calendar), start.addingTimeInterval(60))
        return start...end
    }

    /// 一根柱子所代表时段的标题，用于悬停浮层和峰值说明。
    func barTitle(start: Date, end: Date) -> String {
        switch chartUnit {
        case .minute:
            return start.formatted(date: .omitted, time: .shortened)
        case .hour:
            let format = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute()
            return "\(start.formatted(format)) – \(end.formatted(format))"
        default:
            return start.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated))
        }
    }
}

@MainActor
private func totalBytes(of record: DailyUsageRecord) -> Int64 {
    saturatingAdd(record.downloadBytes, record.uploadBytes)
}

private func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? Int64.max : result.partialValue
}

@MainActor
private func percentText(_ fraction: Double) -> String {
    guard fraction > 0 else { return "0%" }
    if fraction < 0.01 { return "<1%" }
    return fraction.formatted(.percent.precision(.fractionLength(0)))
}

// MARK: - 顶部总量与趋势

private struct OverviewHeader: View {
    @ObservedObject var model: ByteTraceViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 36) {
            totalBlock
                .frame(width: 250, alignment: .leading)
            TrendChart(bars: model.rangeBars, range: model.selectedRange)
        }
    }

    private var totalBlock: some View {
        let totals = model.selectedRangeTotals
        let split = model.routeSplit(for: model.rangeRecords)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rangeCaption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ByteAmountText(bytes: totals.totalBytes)
            }

            if split.hasKnownRoute {
                VStack(alignment: .leading, spacing: 6) {
                    RouteSegmentBar(split: split, height: 6)
                    HStack(spacing: 14) {
                        legend(color: RouteColor.direct, title: "直连", bytes: split.directBytes)
                        legend(color: RouteColor.proxy, title: "代理", bytes: split.proxyBytes)
                    }
                }
                .help(RouteSplitCard.help(for: split))
                Text("↓ \(ByteTraceViewModel.formatBytes(totals.downloadBytes))　↑ \(ByteTraceViewModel.formatBytes(totals.uploadBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    DirectionBar(download: totals.downloadBytes, upload: totals.uploadBytes)
                    HStack(spacing: 14) {
                        legend(color: TrafficColor.download, title: "下行", bytes: totals.downloadBytes)
                        legend(color: TrafficColor.upload, title: "上行", bytes: totals.uploadBytes)
                    }
                }
            }

            if let note = routeNote(split) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monospacedDigit()
    }

    private var rangeCaption: String {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        switch model.selectedRange {
        case .lastHour:
            return "最近 1 小时"
        case .today:
            return "今天 · \(now.formatted(.dateTime.month().day().weekday(.wide)))"
        case .thisWeek:
            let start = model.selectedRange.startDate(relativeTo: now, calendar: calendar)
            return "本周 · \(start.formatted(.dateTime.month().day())) 起"
        case .thisMonth:
            return "本月 · \(now.formatted(.dateTime.year().month()))"
        }
    }

    /// 只在口径需要说明时给一行注释：按今天估算、出口未知、路径统计启用前的流量。
    private func routeNote(_ split: RouteSplit) -> String? {
        guard split.hasKnownRoute else { return nil }
        var parts: [String] = []
        if model.routeBreakdownUsesToday {
            parts.append("直连 / 代理按今天的比例估算")
        }
        if split.unknownBytes > 0 {
            parts.append("另有 \(ByteTraceViewModel.formatBytes(split.unknownBytes)) 出口未知")
        }
        if split.isPartial, split.unattributedBytes > 0 {
            parts.append("\(ByteTraceViewModel.formatBytes(split.unattributedBytes)) 未区分（统计启用前）")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    private func legend(color: Color, title: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
            Text(ByteTraceViewModel.formatBytes(bytes))
        }
        .font(.callout)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// 数字大、单位小的字节数，与菜单栏面板的今日总量同一写法。
private struct ByteAmountText: View {
    let bytes: Int64

    var body: some View {
        let parts = ByteTraceViewModel.formatBytes(bytes).split(separator: " ", maxSplits: 1)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(parts.first.map(String.init) ?? "0")
                .font(.system(size: 46, weight: .semibold))
                .contentTransition(.numericText())
                .animation(.smooth, value: bytes)
            if parts.count > 1 {
                Text(String(parts[1]))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}

/// 没有路径记录时代替直连 / 代理条，显示下行与上行的比例。
private struct DirectionBar: View {
    let download: Int64
    let upload: Int64

    var body: some View {
        GeometryReader { geometry in
            let total = Double(download) + Double(upload)
            let downloadFraction = total > 0 ? Double(download) / total : 0
            HStack(spacing: 1) {
                if download > 0 {
                    Rectangle()
                        .fill(TrafficColor.download)
                        .frame(width: max(0, geometry.size.width * downloadFraction - (upload > 0 ? 1 : 0)))
                }
                if upload > 0 {
                    Rectangle()
                        .fill(TrafficColor.upload)
                }
            }
        }
        .frame(height: 6)
        .background(Color.primary.opacity(0.06))
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// 顶部趋势图：只画合计，悬停时浮层给出上下行与该时段流量最大的应用。
private struct TrendChart: View {
    let bars: [UsageChartBar]
    let range: UsageTimeRange

    @State private var hoveredBar: UsageChartBar?
    @State private var hoverX: CGFloat = 0

    private static let chartHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(range.chartUnitTitle)
                Spacer()
                if let peak {
                    Text("峰值 \(range.barTitle(start: peak.start, end: peak.end)) · \(ByteTraceViewModel.formatBytes(peak.totalBytes))")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if bars.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("统计运行一段时间后会在这里显示趋势")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.chartHeight)
            } else {
                chart
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: bars) { _, newBars in
            if let hoveredBar, !newBars.contains(where: { $0.start == hoveredBar.start }) {
                self.hoveredBar = nil
            }
        }
    }

    private var peak: UsageChartBar? {
        guard let bar = bars.max(by: { $0.totalBytes < $1.totalBytes }), bar.totalBytes > 0 else { return nil }
        return bar
    }

    private var chart: some View {
        let calendar = Calendar.autoupdatingCurrent
        let unit = range.chartUnit
        return Chart(bars) { bar in
            BarMark(
                x: .value("时间", bar.start, unit: unit),
                y: .value("字节", bar.totalBytes)
            )
            .foregroundStyle(TrafficColor.download.opacity(opacity(for: bar)))
            .cornerRadius(2)
        }
        .chartXScale(domain: range.chartDomain(now: Date(), calendar: calendar))
        .chartXAxis {
            AxisMarks(values: .stride(by: range.axisStride.component, count: range.axisStride.count)) { _ in
                AxisTick(length: 3, stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: range.axisFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
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
        .frame(height: Self.chartHeight)
    }

    private func opacity(for bar: UsageChartBar) -> Double {
        guard let hoveredBar else { return 0.85 }
        return hoveredBar.start == bar.start ? 1 : 0.35
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
            Text(range.barTitle(start: bar.start, end: bar.end))
                .font(.caption.weight(.semibold))
            Text("\(ByteTraceViewModel.formatBytes(bar.totalBytes))　↓ \(ByteTraceViewModel.formatBytes(bar.downloadBytes))　↑ \(ByteTraceViewModel.formatBytes(bar.uploadBytes))")
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
}

// MARK: - 列表行与行下详情

/// 列表行：图标 | 名称与浅色说明 | 合计 | 占比 | 展开箭头。
private struct UsageRow: View {
    let record: DailyUsageRecord
    let share: Double
    let note: String?
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(record: record, size: 22)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(record.displayName)
                    .fontWeight(isExpanded ? .semibold : .regular)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 这里刻意不加 .contentTransition(.numericText())：列表每次刷新数值都会变化，
            // 逐行数字滚动动画会让整个可见列表持续重绘。
            Text(ByteTraceViewModel.formatBytes(totalBytes(of: record)))
                .fontWeight(.medium)
            Text(percentText(share))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(note ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// 行下展开的详情：趋势小图、下行 / 上行、直连 / 代理、排名与路径。
private struct AppDetailPanel: View {
    let record: DailyUsageRecord
    let rank: Int
    let rankCount: Int
    @ObservedObject var model: ByteTraceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            timeline

            HStack(alignment: .top, spacing: 16) {
                stat("下行 / 上行") {
                    Text("\(ByteTraceViewModel.formatBytes(record.downloadBytes)) / \(ByteTraceViewModel.formatBytes(record.uploadBytes))")
                }
                routeStat
                stat("排名") {
                    Text("第 \(rank) / \(rankCount)")
                }
            }

            infoLines
        }
        .padding(.leading, 40)
        .padding(.trailing, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .onAppear {
            model.beginObservingAppDetail(record.appKey)
        }
        .onDisappear {
            model.endObservingAppDetail(record.appKey)
        }
    }

    // MARK: 趋势小图

    @ViewBuilder
    private var timeline: some View {
        let range = model.selectedRange
        let points = binnedTimeline(range: range)
        if points.isEmpty {
            Text("当前范围暂无时间粒度数据")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        } else {
            Chart(points, id: \.start) { point in
                BarMark(
                    x: .value("时间", point.start, unit: range.chartUnit),
                    y: .value("字节", point.bytes)
                )
                .foregroundStyle(TrafficColor.download.opacity(0.85))
                .cornerRadius(1.5)
            }
            .chartXScale(domain: range.chartDomain(now: Date(), calendar: Calendar.autoupdatingCurrent))
            .chartXAxis {
                AxisMarks(values: .stride(by: range.axisStride.component, count: range.axisStride.count)) { _ in
                    AxisValueLabel(format: range.axisFormat)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 64)
        }
    }

    /// 分钟桶按图表粒度（今天为每小时）合并，柱子数量与顶部趋势图一致。
    private func binnedTimeline(range: UsageTimeRange) -> [(start: Date, bytes: Int64)] {
        let calendar = Calendar.autoupdatingCurrent
        var bins: [Date: Int64] = [:]
        for point in model.timeline(for: record.appKey) {
            let start = calendar.dateInterval(of: range.chartUnit, for: point.start)?.start ?? point.start
            bins[start] = saturatingAdd(bins[start] ?? 0, point.totalBytes)
        }
        return bins.keys.sorted().map { ($0, bins[$0] ?? 0) }
    }

    // MARK: 路径

    @ViewBuilder
    private var routeStat: some View {
        let split = model.routeSplit(for: [record])
        stat(model.routeBreakdownUsesToday ? "直连 / 代理 · 按今天估算" : "直连 / 代理") {
            if split.hasKnownRoute {
                VStack(alignment: .leading, spacing: 5) {
                    RouteSegmentBar(split: split, height: 5)
                    Text(routeText(split))
                }
            } else {
                Text("暂无路径记录")
                    .foregroundStyle(.secondary)
            }
        }
        .help(split.hasKnownRoute ? RouteSplitCard.help(for: split) : "")
    }

    /// 覆盖足够时给比例；大部分流量没有路径记录时只给字节数。
    private func routeText(_ split: RouteSplit) -> String {
        if split.isRepresentative {
            return "直连 \(percentText(split.fraction(of: split.directBytes))) · 代理 \(percentText(split.fraction(of: split.proxyBytes)))"
        }
        return "直连 \(ByteTraceViewModel.formatBytes(split.directBytes)) · 代理 \(ByteTraceViewModel.formatBytes(split.proxyBytes))"
    }

    // MARK: 说明与路径

    @ViewBuilder
    private var infoLines: some View {
        let subtitle = model.detailSubtitle(for: record)
        let path = record.bundlePath ?? record.executablePath
        if subtitle != nil || path != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let path {
                    Text(ByteTraceViewModel.abbreviatedPath(path))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func stat<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            content()
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
