import AppKit
import Charts
import ByteTraceCore
import SwiftUI

/// 主窗口统计页：顶部总量与趋势并排；下方按应用排行，展开查看其中各程序。
/// 没有 GUI 应用的流量归到 macOS 系统 / 命令行工具。
/// 点击一行在行下展开详情。代理传输不计入总量，不在列表里展示。
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
    private static let collapsedRowLimit = 20
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
        // 同名判断按搜索前的完整列表计算，搜索时不变。
        let ranked = model.rangeApplicationRecords
        let listsAll = listsAllRows(count: records.count)
        let visible = listsAll ? records : Array(records.prefix(Self.collapsedRowLimit))
        let duplicateNames = ByteTraceViewModel.duplicateDisplayNames(in: ranked)
        let shareBase = model.selectedRangeTotals.totalBytes

        return VStack(alignment: .leading, spacing: 4) {
            listHeader(count: records.count, detail: listDetail(records: records))

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

    private func listHeader(count: Int, detail: String?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("应用")
                    .font(.headline)
                Text("\(count)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if let detail {
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
                parts.append("代理 \(percent)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func rowWithDetail(
        _ record: DailyUsageRecord,
        share: Double,
        note: String?,
        showsDivider: Bool
    ) -> some View {
        let isExpanded = expandedAppKey == record.appKey
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpansion(of: record.appKey)
            } label: {
                UsageRow(
                    iconRecord: record,
                    name: record.displayName,
                    totalBytes: totalBytes(of: record),
                    share: share,
                    note: note,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            .interactiveHoverHighlight(cornerRadius: 8, opacity: isExpanded ? 0 : 0.045)
            .pointingHandCursor()
            .focusable(false)
            .accessibilityHint(isExpanded ? "收起详情" : "展开详情")

            if isExpanded {
                AppDetailPanel(
                    record: record,
                    model: model
                )
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

    /// 行内名称后的浅色说明：系统进程用途、运行过的程序；同名不同路径时补上路径。
    private func rowNote(for record: DailyUsageRecord, duplicateNames: Set<String>) -> String? {
        if let subtitle = model.rangeSubtitle(for: record) { return subtitle }
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
        .focusable(false)
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

private extension UsageRangeWindow {
    var axisStride: (component: Calendar.Component, count: Int) {
        if chartUnit == .hour { return (.hour, 6) }
        let calendar = Calendar.autoupdatingCurrent
        let count = calendar.dateComponents([chartUnit], from: chartDomain.lowerBound, to: chartDomain.upperBound)
            .value(for: chartUnit) ?? 1
        return (chartUnit, max(1, Int(ceil(Double(count) / 6))))
    }

    var axisFormat: Date.FormatStyle {
        switch chartUnit {
        case .hour: return .dateTime.hour()
        case .month: return .dateTime.year().month(.defaultDigits)
        case .year: return .dateTime.year()
        default: return .dateTime.month(.defaultDigits).day()
        }
    }

    var chartDomain: ClosedRange<Date> {
        let calendar = Calendar.autoupdatingCurrent
        let lower = calendar.dateInterval(of: chartUnit, for: start)?.start ?? start
        // 月 / 年柱画满所在周期，避免首尾柱被裁掉；查询仍截止到实际 end。
        let upper: Date
        if chartUnit == .month || chartUnit == .year {
            upper = calendar.dateInterval(of: chartUnit, for: lastDay)?.end ?? chartEnd
        } else {
            upper = chartEnd
        }
        return lower...max(upper, lower.addingTimeInterval(60))
    }

    /// 一根柱子所代表时段的标题，用于悬停浮层和峰值说明。
    func barTitle(start: Date, end: Date) -> String {
        switch chartUnit {
        case .hour:
            let format = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .omitted)).minute()
            return "\(start.formatted(format)) – \(end.formatted(format))"
        case .month:
            return start.formatted(.dateTime.year().month())
        case .year:
            return start.formatted(.dateTime.year())
        default:
            return start.formatted(.dateTime.year().month(.defaultDigits).day())
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
            TrendChart(bars: model.rangeBars, window: model.rangeWindow)
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
                Text("↑ \(ByteTraceViewModel.formatBytes(totals.uploadBytes))　↓ \(ByteTraceViewModel.formatBytes(totals.downloadBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    DirectionBar(download: totals.downloadBytes, upload: totals.uploadBytes)
                    HStack(spacing: 14) {
                        legend(color: TrafficColor.upload, title: "上行", bytes: totals.uploadBytes)
                        legend(color: TrafficColor.download, title: "下行", bytes: totals.downloadBytes)
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
        let start = model.rangeWindow.start
        switch model.selectedRange {
        case .today:
            return "今日 · \(start.formatted(.dateTime.month().day().weekday(.wide)))"
        case .thisWeek:
            return "本周 · \(start.formatted(.dateTime.month().day())) 起"
        case .thisMonth:
            return "本月 · \(start.formatted(.dateTime.year().month()))"
        case .lastMonth:
            return "上月 · \(start.formatted(.dateTime.year().month()))"
        case .all:
            guard !model.rangeApplicationRecords.isEmpty else { return "全部" }
            return "全部 · \(start.formatted(.dateTime.year().month(.defaultDigits).day())) 起"
        }
    }

    /// 只在口径需要说明时给一行注释：出口未知、路径统计启用前的流量。
    private func routeNote(_ split: RouteSplit) -> String? {
        guard split.hasKnownRoute else { return nil }
        var parts: [String] = []
        if split.unknownBytes > 0 {
            parts.append("另有 \(ByteTraceViewModel.formatBytes(split.unknownBytes)) 出口未知")
        }
        if split.isPartial, split.unattributedBytes > 0 {
            parts.append("\(ByteTraceViewModel.formatBytes(split.unattributedBytes)) 未区分（统计启用前）")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    private func legend(color: Color, title: String, bytes: Int64) -> some View {
        LegendLabel(color: color, title: title, value: ByteTraceViewModel.formatBytes(bytes))
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

/// 没有路径记录时代替直连 / 代理条，显示上行与下行的比例（上行在左，与菜单栏面板一致）。
private struct DirectionBar: View {
    let download: Int64
    let upload: Int64

    var body: some View {
        GeometryReader { geometry in
            let total = Double(download) + Double(upload)
            let uploadFraction = total > 0 ? Double(upload) / total : 0
            HStack(spacing: 1) {
                if upload > 0 {
                    Rectangle()
                        .fill(TrafficColor.upload)
                        .frame(width: max(0, geometry.size.width * uploadFraction - (download > 0 ? 1 : 0)))
                }
                if download > 0 {
                    Rectangle()
                        .fill(TrafficColor.download)
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
    let window: UsageRangeWindow

    @State private var hoveredBar: UsageChartBar?
    @State private var hoverX: CGFloat = 0

    private static let chartHeight: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.chartUnitTitle)
                Spacer()
                if let peak {
                    Text("峰值 \(window.barTitle(start: peak.start, end: peak.end)) · \(ByteTraceViewModel.formatBytes(peak.totalBytes))")
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
                    Text("所选时间范围暂无趋势数据")
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
        let unit = window.chartUnit
        return Chart(bars) { bar in
            BarMark(
                x: .value("时间", bar.start, unit: unit),
                y: .value("字节", bar.totalBytes)
            )
            .foregroundStyle(TrafficColor.download.opacity(opacity(for: bar)))
            .cornerRadius(2)
        }
        .chartXScale(domain: window.chartDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: window.axisStride.component, count: window.axisStride.count)) { _ in
                AxisTick(length: 3, stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: window.axisFormat)
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
            Text(window.barTitle(start: bar.start, end: bar.end))
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

/// 应用列表行：图标 | 名称与浅色说明 | 合计 | 占比 | 展开箭头。
private struct UsageRow: View {
    let iconRecord: DailyUsageRecord
    let name: String
    let totalBytes: Int64
    let share: Double
    let note: String?
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(record: iconRecord, size: 22)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name)
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
            Text(ByteTraceViewModel.formatBytes(totalBytes))
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

/// 行下详情的排版参数，与 `UsageRow` 的列对齐。
private enum DetailLayout {
    /// 父行名称的起点：行内边距 8 + 图标 22 + 间距 10。
    static let rowLeading: CGFloat = 40
    /// 子行图标宽度，与父行图标一致，行高也一致。
    static let markerWidth: CGFloat = 22
    /// 子行名称的起点，分隔线从这里开始。
    static let textLeading: CGFloat = rowLeading + markerWidth + 10
    /// 父行右侧占比列的终点到行尾：箭头 12 + 间距 10 + 行内边距 8。
    static let trailingToShareColumn: CGFloat = 30
    /// 子行上行、下行两列的宽度，容纳「↑ 999.9 MB」。
    static let directionColumnWidth: CGFloat = 76
}

/// 行下展开的详情：趋势小图，一行上行 / 下行与直连 / 代理图例，宿主里的程序排行，最后是用途说明与路径。
/// 只有程序这类实体用列表行；比例用图例，与顶部总览同一写法。
private struct AppDetailPanel: View {
    let record: DailyUsageRecord
    @ObservedObject var model: ByteTraceViewModel

    private static let programLimit = 8
    private static let domainLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailTimelineChart(points: model.timeline(for: record.appKey), window: model.rangeWindow)
                .padding(.trailing, DetailLayout.trailingToShareColumn)
                .padding(.bottom, 8)
                .padding(.leading, DetailLayout.rowLeading)

            legendLine
                .padding(.leading, DetailLayout.rowLeading)
                .padding(.trailing, 8)

            programSection
            domainSection

            footnote
                .padding(.leading, DetailLayout.rowLeading)
                .padding(.trailing, DetailLayout.trailingToShareColumn)
                .padding(.top, 10)
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
        .onAppear {
            model.beginObservingAppDetail(record.appKey)
        }
        .onDisappear {
            model.endObservingAppDetail(record.appKey)
        }
    }

    // MARK: 上行 / 下行、直连 / 代理

    /// 上行在前，与菜单栏面板一致。直连 / 代理的比例只在已区分路径的流量里计算，
    /// 覆盖不足一半时只给字节数；没有路径记录时不显示这一组。出口未知与未区分放在悬停说明里。
    private var legendLine: some View {
        let split = model.routeSplit(for: [record])
        return HStack(spacing: 14) {
            LegendLabel(color: TrafficColor.upload, title: "上行", value: ByteTraceViewModel.formatBytes(record.uploadBytes))
            LegendLabel(color: TrafficColor.download, title: "下行", value: ByteTraceViewModel.formatBytes(record.downloadBytes))
            if split.hasKnownRoute {
                HStack(spacing: 14) {
                    LegendLabel(color: RouteColor.direct, title: "直连", value: routeValue(split.directBytes, in: split))
                    LegendLabel(color: RouteColor.proxy, title: "代理", value: routeValue(split.proxyBytes, in: split))
                }
                .padding(.leading, 10)
                .help(RouteSplitCard.help(for: split))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func routeValue(_ bytes: Int64, in split: RouteSplit) -> String {
        split.isRepresentative
            ? percentText(split.fraction(of: bytes))
            : ByteTraceViewModel.formatBytes(bytes)
    }

    // MARK: 程序排行

    /// 宿主里运行过其他程序时列出排行；只有应用自身时不显示。
    @ViewBuilder
    private var programSection: some View {
        let programs = model.programs(forHost: record)
        if programs.contains(where: { !$0.isApplicationItself }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("程序")
                        .foregroundStyle(.secondary)
                    Text("\(programs.count)")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .monospacedDigit()
                .padding(.leading, DetailLayout.rowLeading)
                .padding(.top, 14)
                .padding(.bottom, 2)

                DetailRowGroup(rows: programRows(programs))
            }
        }
    }

    /// 前几项之外合成「其他 N 个」；只多出一项时直接列出。占比按宿主总量计算。
    private func programRows(_ programs: [HostProgramShare]) -> [DetailRow.Item] {
        let hostBytes = totalBytes(of: record)
        var rows = programs.map { program in
            let split = model.routeSplit(
                forHost: record.appKey,
                programKey: program.programKey,
                totalBytes: program.bytes
            )
            // 说明写法同应用行：系统进程的用途在前，代理占比在后。
            let note = [
                program.description,
                split.isRepresentative ? "代理 \(percentText(split.proxyFraction))" : nil
            ].compactMap { $0 }.joined(separator: " · ")
            return DetailRow.Item(
                id: program.programKey.isEmpty ? record.appKey : program.programKey,
                marker: .icon(program.iconRecord),
                name: program.name,
                note: note.isEmpty ? nil : note,
                uploadBytes: program.uploadBytes,
                downloadBytes: program.downloadBytes,
                bytes: program.bytes,
                share: fraction(program.bytes, of: hostBytes)
            )
        }
        if rows.count > Self.programLimit + 1 {
            let rest = rows.dropFirst(Self.programLimit)
            let restBytes = rest.reduce(Int64(0)) { saturatingAdd($0, $1.bytes) }
            let restUpload = rest.reduce(Int64(0)) { saturatingAdd($0, $1.uploadBytes) }
            let restDownload = rest.reduce(Int64(0)) { saturatingAdd($0, $1.downloadBytes) }
            rows = Array(rows.prefix(Self.programLimit))
            rows.append(DetailRow.Item(
                id: "otherPrograms",
                marker: .symbol("ellipsis"),
                name: "其他 \(rest.count) 个",
                note: nil,
                uploadBytes: restUpload,
                downloadBytes: restDownload,
                bytes: restBytes,
                share: fraction(restBytes, of: hostBytes)
            ))
        }
        return rows
    }

    @ViewBuilder
    private var domainSection: some View {
        let domains = model.detailDomains.filter { $0.appKey == record.appKey }
        if !domains.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("域名")
                        .foregroundStyle(.secondary)
                    Text("\(domains.count)")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .monospacedDigit()
                .padding(.leading, DetailLayout.rowLeading)
                .padding(.top, 14)
                .padding(.bottom, 2)

                DetailRowGroup(rows: domainRows(domains))
            }
        }
    }

    private func domainRows(_ domains: [ByteTraceExportDocument.DomainUsage]) -> [DetailRow.Item] {
        let hostBytes = totalBytes(of: record)
        let displayedCount = domains.count > Self.domainLimit + 1 ? Self.domainLimit : domains.count
        var rows = domains.prefix(displayedCount).map { domain in
            DetailRow.Item(
                id: "domain:\(domain.domain)",
                marker: .symbol("globe"),
                name: domain.domain,
                note: domainRouteNote(domain),
                uploadBytes: domain.uploadBytes,
                downloadBytes: domain.downloadBytes,
                bytes: domain.totalBytes,
                share: fraction(domain.totalBytes, of: hostBytes)
            )
        }
        let remaining = domains.dropFirst(displayedCount)
        if !remaining.isEmpty {
            let bytes = remaining.reduce(Int64(0)) { saturatingAdd($0, $1.totalBytes) }
            let upload = remaining.reduce(Int64(0)) { saturatingAdd($0, $1.uploadBytes) }
            let download = remaining.reduce(Int64(0)) { saturatingAdd($0, $1.downloadBytes) }
            rows.append(DetailRow.Item(
                id: "otherDomains", marker: .symbol("ellipsis"), name: "其他 \(remaining.count) 个",
                note: nil, uploadBytes: upload, downloadBytes: download,
                bytes: bytes, share: fraction(bytes, of: hostBytes)
            ))
        }
        let identified = domains.reduce(Int64(0)) { saturatingAdd($0, $1.totalBytes) }
        let identifiedUpload = domains.reduce(Int64(0)) { saturatingAdd($0, $1.uploadBytes) }
        let identifiedDownload = domains.reduce(Int64(0)) { saturatingAdd($0, $1.downloadBytes) }
        let unknown = max(hostBytes - identified, 0)
        if unknown > 0 {
            rows.append(DetailRow.Item(
                id: "unknownDomain", marker: .symbol("questionmark"), name: "未识别域名",
                note: nil,
                uploadBytes: max(record.uploadBytes - identifiedUpload, 0),
                downloadBytes: max(record.downloadBytes - identifiedDownload, 0),
                bytes: unknown, share: fraction(unknown, of: hostBytes),
                help: "包括未经过 mihomo 的直连、未匹配到域名的连接和开启记录前的历史流量。"
            ))
        }
        return rows
    }

    private func domainRouteNote(_ domain: ByteTraceExportDocument.DomainUsage) -> String? {
        let node = domain.routeBytes[TrafficRoute.proxyNode.rawValue, default: 0]
        let direct = domain.routeBytes[TrafficRoute.proxyRuleDirect.rawValue, default: 0]
        let unknown = domain.routeBytes[TrafficRoute.proxied.rawValue, default: 0]
        if unknown > 0, node == 0, direct == 0 { return "经代理" }
        if node == domain.totalBytes { return "代理" }
        if direct == domain.totalBytes { return "规则直连" }
        if node > 0 {
            return "代理 \(percentText(fraction(node, of: domain.totalBytes)))"
        }
        return direct > 0 ? "含规则直连" : nil
    }

    // MARK: 用途说明与路径

    @ViewBuilder
    private var footnote: some View {
        let subtitle = model.detailSubtitle(for: record)
        let path = record.bundlePath ?? record.executablePath
        if subtitle != nil || path != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let subtitle {
                    // 虚拟宿主的说明较长，允许换行。
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let path {
                    Text(ByteTraceViewModel.abbreviatedPath(path))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fraction(_ bytes: Int64, of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(bytes) / Double(total))
    }
}

/// 圆点 + 浅色标题 + 数值，顶部总览与行下详情共用。
private struct LegendLabel: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .font(.callout)
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// 一组详情行，行间分隔线从名称处开始，与应用列表一致。
private struct DetailRowGroup: View {
    let rows: [DetailRow.Item]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows) { item in
                DetailRow(item: item)
                    .overlay(alignment: .bottom) {
                        if item.id != rows.last?.id {
                            Divider()
                                .padding(.leading, DetailLayout.textLeading)
                        }
                    }
            }
        }
    }
}

/// 详情里的一行，列与 `UsageRow` 对齐：缩进到父行名称处 | 标记 | 名称与浅色说明 | 字节 | 占比 | 箭头占位。
private struct DetailRow: View {
    enum Marker {
        case icon(DailyUsageRecord)
        case symbol(String)
    }

    struct Item: Identifiable {
        let id: String
        let marker: Marker
        let name: String
        let note: String?
        let uploadBytes: Int64
        let downloadBytes: Int64
        let bytes: Int64
        let share: Double
        var help: String? = nil
    }

    let item: Item

    var body: some View {
        HStack(spacing: 10) {
            marker
                .frame(width: DetailLayout.markerWidth, height: DetailLayout.markerWidth)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let note = item.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 上行在前、下行在后；放在总量之前，保证总量与占比两列仍与父行对齐。
            directionText("↑", color: TrafficColor.upload, bytes: item.uploadBytes)
            directionText("↓", color: TrafficColor.download, bytes: item.downloadBytes)
            Text(ByteTraceViewModel.formatBytes(item.bytes))
            Text(percentText(item.share))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
            // 父行箭头列的占位，保证字节与占比两列对齐。
            Color.clear
                .frame(width: 12, height: 1)
        }
        .monospacedDigit()
        .padding(.leading, DetailLayout.rowLeading)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(item.help ?? item.note ?? "")
        .accessibilityElement(children: .combine)
    }

    private func directionText(_ arrow: String, color: Color, bytes: Int64) -> some View {
        Text("\(Text(arrow).foregroundStyle(color)) \(ByteTraceViewModel.formatBytes(bytes))")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: DetailLayout.directionColumnWidth, alignment: .trailing)
    }

    @ViewBuilder
    private var marker: some View {
        switch item.marker {
        case .icon(let record):
            AppIconView(record: record, size: DetailLayout.markerWidth)
        case .symbol(let name):
            Image(systemName: name)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 行下详情里的趋势小图；分钟桶按图表粒度（今天为每小时）合并，柱子数量与顶部趋势图一致。
private struct DetailTimelineChart: View {
    let points: [UsageTimelinePoint]
    let window: UsageRangeWindow

    var body: some View {
        let bins = binned()
        if bins.isEmpty {
            Text("当前范围暂无时间粒度数据")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        } else {
            Chart(bins, id: \.start) { point in
                BarMark(
                    x: .value("时间", point.start, unit: window.chartUnit),
                    y: .value("字节", point.bytes)
                )
                .foregroundStyle(TrafficColor.download.opacity(0.85))
                .cornerRadius(1.5)
            }
            .chartXScale(domain: window.chartDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: window.axisStride.component, count: window.axisStride.count)) { _ in
                    AxisValueLabel(format: window.axisFormat)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 64)
        }
    }

    private func binned() -> [(start: Date, bytes: Int64)] {
        let calendar = Calendar.autoupdatingCurrent
        var bins: [Date: Int64] = [:]
        for point in points {
            let start = calendar.dateInterval(of: window.chartUnit, for: point.start)?.start ?? point.start
            bins[start] = saturatingAdd(bins[start] ?? 0, point.totalBytes)
        }
        return bins.keys.sorted().map { ($0, bins[$0] ?? 0) }
    }
}
