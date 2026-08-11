import AppKit
import Charts
import ByteTraceCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var model: ByteTraceViewModel
    @State private var selection: MainWindowPage = .overview
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("概览", systemImage: "chart.bar.xaxis")
                    .tag(MainWindowPage.overview)
                Label("设置", systemImage: "gearshape")
                    .tag(MainWindowPage.settings)
            }
            .listStyle(.sidebar)
            .navigationTitle("ByteTrace")
        } detail: {
            switch selection {
            case .overview:
                MainOverviewView(model: model)
            case .settings:
                SettingsView(model: model)
            }
        }
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 620, idealHeight: 720)
        .onAppear {
            selection = model.requestedMainWindowPage
            ByteTraceAppDelegate.installOpenMainWindowAction { openWindow(id: "main") }
            ByteTraceAppDelegate.prepareMainWindow()
            NSApplication.shared.activate(ignoringOtherApps: true)
            model.beginObservingUsage()
        }
        .onDisappear {
            model.endObservingUsage()
        }
        .onChange(of: model.requestedMainWindowPage) { _, page in
            selection = page
        }
        .background(MainWindowRegistration())
    }
}

private struct MainOverviewView: View {
    @ObservedObject var model: ByteTraceViewModel
    @State private var searchText = ""
    @State private var isProxyExpanded = true
    @State private var isSystemExpanded = true
    @State private var showsAllApplications = false
    @State private var showsAllProxy = false
    @State private var showsAllSystem = false
    @State private var path = NavigationPath()

    private let collapsedRowLimit = 10

    private var applicationRecords: [DailyUsageRecord] {
        filtered(model.rangeRecords.filter { $0.category == .userApp || $0.category == .unclassified })
    }

    private var proxyRecords: [DailyUsageRecord] {
        filtered(model.rangeRecords.filter { $0.category == .proxyTransport })
    }

    private var systemRecords: [DailyUsageRecord] {
        filtered(model.rangeRecords.filter { $0.category == .systemProcess })
    }

    private func filtered(_ records: [DailyUsageRecord]) -> [DailyUsageRecord] {
        guard !searchText.isEmpty else { return records }
        return records.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rangePicker
                    summary
                    timeline
                    applicationSection
                    if !proxyRecords.isEmpty {
                        CollapsibleUsageSection(
                            title: "代理运输流量",
                            count: proxyRecords.count,
                            symbolName: "arrow.triangle.2.circlepath",
                            tint: .purple,
                            isExpanded: $isProxyExpanded
                        ) {
                            usageRows(proxyRecords, showsAll: $showsAllProxy)
                        }
                    }
                    if model.showsSystemProcesses, !systemRecords.isEmpty {
                        CollapsibleUsageSection(
                            title: "系统与后台进程",
                            count: systemRecords.count,
                            symbolName: "gearshape.2",
                            tint: .secondary,
                            isExpanded: $isSystemExpanded
                        ) {
                            usageRows(systemRecords, showsAll: $showsAllSystem)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("概览")
            .toolbar {
                ToolbarItem {
                    Button {
                        model.refresh()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
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
        }
    }

    private var rangePicker: some View {
        Picker("时间范围", selection: $model.selectedRange) {
            ForEach(UsageTimeRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 620)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            TrafficStatCard(
                title: "总量",
                value: model.selectedRangeTotals.totalBytes,
                symbolName: "arrow.up.arrow.down",
                tint: .accentColor
            )
            TrafficStatCard(
                title: "下载",
                value: model.selectedRangeTotals.downloadBytes,
                symbolName: "arrow.down",
                tint: .blue
            )
            TrafficStatCard(
                title: "上传",
                value: model.selectedRangeTotals.uploadBytes,
                symbolName: "arrow.up",
                tint: .orange
            )
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("流量趋势")
                    .font(.title3.weight(.semibold))
                Spacer()
                HStack(spacing: 14) {
                    legendDot(color: .blue, label: "下载")
                    legendDot(color: .orange, label: "上传")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(model.selectedRange.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.rangeTimeline.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("暂无时间粒度数据")
                        .font(.subheadline.weight(.medium))
                    Text("统计运行一段时间后会在这里显示趋势。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)
            } else {
                UsageTimelineChart(points: model.rangeTimeline)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }

    private var applicationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("应用流量")
                    .font(.title3.weight(.semibold))
                Text("\(applicationRecords.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("按名称搜索", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if applicationRecords.isEmpty {
                Text(searchText.isEmpty ? "当前时间范围内暂无应用流量" : "没有匹配“\(searchText)”的应用")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                usageRows(applicationRecords, showsAll: $showsAllApplications)
            }
        }
    }

    private func usageRows(_ records: [DailyUsageRecord], showsAll: Binding<Bool>) -> some View {
        let isTruncatable = searchText.isEmpty && records.count > collapsedRowLimit
        let visible = (isTruncatable && !showsAll.wrappedValue) ? Array(records.prefix(collapsedRowLimit)) : records
        let duplicateNames = ByteTraceViewModel.duplicateDisplayNames(in: records)
        return VStack(spacing: 0) {
            LazyVStack(spacing: 0) {
                ForEach(visible, id: \.appKey) { record in
                    NavigationLink(value: record.appKey) {
                        MainUsageRow(
                            record: record,
                            showsPathHint: duplicateNames.contains(record.displayName)
                        )
                    }
                    .buttonStyle(ByteTraceActionButtonStyle())
                    .pointingHandCursor()
                    if record.appKey != visible.last?.appKey {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
            if isTruncatable {
                Divider()
                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        showsAll.wrappedValue.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsAll.wrappedValue ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                        Text(showsAll.wrappedValue ? "收起" : "显示全部 \(records.count) 个")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .interactiveHoverHighlight()
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 只在行集合本身变化（展开/收起、排名变动、增删应用）时做布局动画。
        // 原本绑定整个 [DailyUsageRecord]，任何一行字节数变化都会触发整个容器重新布局。
        .animation(.smooth, value: visible.map(\.appKey))
    }

    private func totalBytes(for record: DailyUsageRecord) -> Int64 {
        let result = record.downloadBytes.addingReportingOverflow(record.uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}

private struct UsageTimelineChart: View {
    let points: [UsageTimelinePoint]

    @State private var hoverPoint: UsageTimelinePoint?
    @State private var hoverLocation: CGPoint?

    private struct Slice: Identifiable {
        let id: Int
        let start: Date
        let seriesKey: String
        let bytes: Int64
    }

    private struct ChartData {
        let slices: [Slice]
        let domain: [String]
        let range: [Color]
    }

    /// 一次遍历同时产出绘图数据与配色标度。
    ///
    /// 原实现有两个问题：`colorScale` 对每个点做 `Array.contains` 线性查找（O(n²)），
    /// `slices` 又单独遍历一遍并为每个切片做字符串插值构造 id。「今天」范围下
    /// 分钟桶聚合出的点数可达上千，这些都发生在每次 body 求值时。
    ///
    /// domain 的追加顺序与原实现一致（每遇到新 segment 先 download 后 upload），
    /// 配色结果不变。
    private var chartData: ChartData {
        var slices: [Slice] = []
        slices.reserveCapacity(points.count * 2)
        var domain: [String] = []
        var range: [Color] = []
        var keysBySegment: [Int: (download: String, upload: String)] = [:]

        for point in points {
            let keys: (download: String, upload: String)
            if let cached = keysBySegment[point.segmentID] {
                keys = cached
            } else {
                keys = (
                    download: "download#\(point.segmentID)",
                    upload: "upload#\(point.segmentID)"
                )
                keysBySegment[point.segmentID] = keys
                domain.append(keys.download)
                range.append(.blue)
                domain.append(keys.upload)
                range.append(.orange)
            }

            slices.append(
                Slice(
                    id: slices.count,
                    start: point.start,
                    seriesKey: keys.download,
                    bytes: point.downloadBytes
                )
            )
            slices.append(
                Slice(
                    id: slices.count,
                    start: point.start,
                    seriesKey: keys.upload,
                    bytes: point.uploadBytes
                )
            )
        }
        return ChartData(slices: slices, domain: domain, range: range)
    }

    var body: some View {
        let data = chartData
        Chart(data.slices) { slice in
            AreaMark(
                x: .value("时间", slice.start),
                y: .value("字节", slice.bytes)
            )
            .foregroundStyle(by: .value("系列", slice.seriesKey))
            .opacity(0.18)
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("时间", slice.start),
                y: .value("字节", slice.bytes)
            )
            .foregroundStyle(by: .value("系列", slice.seriesKey))
            .lineStyle(StrokeStyle(lineWidth: 1.6))
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(domain: data.domain, range: data.range)
        .chartLegend(.hidden)
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
                            hoverPoint = nil
                            hoverLocation = nil
                        }
                    }
            }
        }
        .overlay {
            GeometryReader { geometry in
                if let hoverPoint, let hoverLocation {
                    let bubbleWidth: CGFloat = 150
                    let clampedX = min(
                        max(hoverLocation.x, bubbleWidth / 2 + 4),
                        geometry.size.width - bubbleWidth / 2 - 4
                    )
                    hoverBubble(for: hoverPoint)
                        .frame(width: bubbleWidth, alignment: .leading)
                        .position(x: clampedX, y: 24)
                }
            }
        }
        .frame(height: 220)
    }

    private func updateHover(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrameAnchor = proxy.plotFrame else { return }
        let plotFrame = geometry[plotFrameAnchor]
        let relativeX = location.x - plotFrame.origin.x
        guard let date = proxy.value(atX: relativeX, as: Date.self) else { return }
        hoverPoint = points.min {
            abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
        }
        hoverLocation = location
    }

    private func hoverBubble(for point: UsageTimelinePoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(point.start.formatted(date: .omitted, time: .shortened))
                .font(.caption2.weight(.semibold))
            HStack(spacing: 10) {
                Label(ByteTraceViewModel.formatBytes(point.downloadBytes), systemImage: "arrow.down")
                    .foregroundStyle(.blue)
                Label(ByteTraceViewModel.formatBytes(point.uploadBytes), systemImage: "arrow.up")
                    .foregroundStyle(.orange)
            }
            .font(.caption2.monospacedDigit())
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

@MainActor
private struct MainWindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView()
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            ByteTraceAppDelegate.registerMainWindow(window)
        }
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
            VStack(alignment: .leading, spacing: 18) {
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
            .padding(24)
        }
        .navigationTitle(record?.displayName ?? "应用详情")
    }

    private func appHeader(_ record: DailyUsageRecord) -> some View {
        HStack(spacing: 14) {
            AppIconView(record: record, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.title2.weight(.semibold))
                Text(model.selectedRange.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func appStats(_ record: DailyUsageRecord) -> some View {
        HStack(spacing: 12) {
            TrafficStatCard(
                title: "总量",
                value: totalBytes(for: record),
                symbolName: "arrow.up.arrow.down",
                tint: .accentColor
            )
            TrafficStatCard(
                title: "下载",
                value: record.downloadBytes,
                symbolName: "arrow.down",
                tint: .blue
            )
            TrafficStatCard(
                title: "上传",
                value: record.uploadBytes,
                symbolName: "arrow.up",
                tint: .orange
            )
        }
    }

    private var appTimeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("应用趋势")
                .font(.title3.weight(.semibold))

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
                    .foregroundStyle(.blue.gradient)
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
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func totalBytes(for record: DailyUsageRecord) -> Int64 {
        let result = record.downloadBytes.addingReportingOverflow(record.uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}

private struct TrafficStatCard: View {
    let title: String
    let value: Int64
    let symbolName: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ByteTraceViewModel.formatBytes(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MainUsageRow: View {
    let record: DailyUsageRecord
    var showsPathHint: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(record: record, size: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text("↓ \(ByteTraceViewModel.formatBytes(record.downloadBytes))")
                    Text("↑ \(ByteTraceViewModel.formatBytes(record.uploadBytes))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                if showsPathHint, let path = record.bundlePath ?? record.executablePath {
                    Text(ByteTraceViewModel.abbreviatedPath(path))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 8)

            // 这里刻意不加 .contentTransition(.numericText())：列表每 10 秒刷新一次且
            // 数值必然变化，逐行数字滚动动画会让整个可见列表持续重绘，是渲染开销的主要来源。
            // 顶部三张统计卡数量固定，仍保留动画作为视觉焦点。
            Text(ByteTraceViewModel.formatBytes(totalBytes))
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var totalBytes: Int64 {
        let result = record.downloadBytes.addingReportingOverflow(record.uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}

private struct AppIconView: View {
    let record: DailyUsageRecord
    let size: CGFloat

    var body: some View {
        if let path = record.bundlePath ?? record.executablePath {
            Image(nsImage: AppIconCache.icon(forPath: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
