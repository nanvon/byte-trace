import AppKit
import ByteTraceCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: ByteTraceViewModel
    private let updater = AppUpdater.shared

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsMoreApplications = false
    /// 滚动内容的实际高度；初值是常见内容的估计，避免首帧高度为 0。
    @State private var contentHeight: CGFloat = 560

    private let collapsedRowLimit = 10
    private let expandedRowLimit = 15

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if showsCollectionControl {
                        statusCard
                            .padding(.bottom, 10)
                    }
                    todayCard
                    usageContent
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    contentHeight = height
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // 面板高度跟随内容，超过屏幕可用高度才滚动。
            .frame(height: min(contentHeight, maxScrollHeight))

            if let version = updater.availableVersion {
                HStack(spacing: 8) {
                    Spacer()
                    Text("新版本 \(version)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Button("下载") {
                        updater.showUpdateWindow()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .focusable(false)
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 390)
        // 不铺不透明底色，保留 MenuBarExtra 窗口的系统材质；卡片自带实底。
        // 面板收起后就没人看数据了，停掉周期性 UI 刷新；重新展开时立即补一次。
        .onAppear { model.beginObservingUsage(.menuBar) }
        .onDisappear { model.endObservingUsage(.menuBar) }
    }

    private var totals: UsageTotals {
        model.todayTotals
    }

    /// 屏幕可用高度减去顶部栏与上下留白。
    private var maxScrollHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        let updateFooterHeight: CGFloat = updater.hasUpdate ? 40 : 0
        return max(320, visibleHeight - 54 - 40 - updateFooterHeight)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ByteTrace")
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.status.tint)
                        .frame(width: 7, height: 7)
                    Text(model.status.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            headerButton(symbolName: "macwindow", label: "打开主窗口") {
                openMainWindow()
            }
            headerButton(symbolName: "gearshape", label: "设置") {
                openSettingsWindow()
            }
            headerButton(symbolName: "power", label: "退出 ByteTrace") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func headerButton(
        symbolName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(ByteTraceActionButtonStyle())
        .pointingHandCursor()
        .focusable(false)
        .accessibilityLabel(label)
        .help(label)
    }

    /// 正常统计时只在顶部显示一行状态；停止或出错时补充原因并给出开始/停止操作。
    private var showsCollectionControl: Bool {
        model.status != .collecting || model.lastError != nil
    }

    /// 状态标题已在顶部显示，这里只补充原因与操作。
    private var statusCard: some View {
        HStack(spacing: 9) {
            Text(model.lastError ?? model.status.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(model.isCollecting ? "停止" : "开始") {
                if model.isCollecting {
                    model.stop()
                } else {
                    model.start()
                }
            }
            .controlSize(.small)
            .pointingHandCursor()
            .focusable(false)
        }
        .padding(12)
        .cardSurface()
    }

    // MARK: - 今日卡片

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日总量")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Text("经代理")
                        .foregroundStyle(.secondary)
                    Text(ByteTraceViewModel.formatBytes(model.todayRouteSplit.proxyBytes))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .font(.body)
                .help(RouteSplitCard.help(for: model.todayRouteSplit))
            }

            totalText

            DirectionShareBar(downloadBytes: totals.downloadBytes, uploadBytes: totals.uploadBytes)

            HStack(spacing: 18) {
                legendValue(color: TrafficColor.upload, title: "上行", bytes: totals.uploadBytes)
                legendValue(color: TrafficColor.download, title: "下行", bytes: totals.downloadBytes)
            }

            Divider()

            HourSparkline(points: model.menuBarHourTimeline)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .cardSurface()
    }

    private var totalText: some View {
        let parts = ByteTraceViewModel.formatBytes(totals.totalBytes).split(separator: " ")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            // 面板里唯一保留数字滚动的地方：总量是视觉焦点且只有一个。
            Text(String(parts.first ?? ""))
                .font(.system(size: 36, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .smooth, value: totals.totalBytes)
            Text(String(parts.dropFirst().first ?? ""))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日总量 \(ByteTraceViewModel.formatBytes(totals.totalBytes))")
    }

    private func legendValue(color: Color, title: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            Text(ByteTraceViewModel.formatBytes(bytes))
                .fontWeight(.semibold)
        }
        .font(.callout)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    // MARK: - 应用列表

    @ViewBuilder
    private var usageContent: some View {
        let applications = model.applicationRecords
        if model.records.isEmpty {
            EmptyTrafficView(status: model.status)
                .padding(.top, 10)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("应用")
                    .font(.body.weight(.semibold))
                Text("\(applications.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("全部应用") {
                    openMainWindow(showsAppList: true)
                }
                .buttonStyle(.link)
                .font(.callout)
                .pointingHandCursor()
                .focusable(false)
            }
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 6)

            VStack(spacing: 0) {
                if applications.isEmpty {
                    Text("暂无应用流量")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    expandableRows(
                        applications,
                        collapsedLimit: collapsedRowLimit,
                        isExpanded: $showsMoreApplications
                    )
                }
            }
            .padding(.vertical, 4)
            .cardSurface()
        }
    }

    /// 折叠时列出前几行，展开到 `expandedRowLimit` 行，仍有剩余时给出跳转主窗口全部应用的入口。
    /// 折叠后只差一行时直接全部列出，不为一行单独放按钮。
    @ViewBuilder
    private func expandableRows(
        _ records: [DailyUsageRecord],
        collapsedLimit: Int,
        isExpanded: Binding<Bool>
    ) -> some View {
        let canExpand = records.count > collapsedLimit + 1
        let expandedCount = min(records.count, expandedRowLimit)
        let visibleCount = canExpand
            ? (isExpanded.wrappedValue ? expandedCount : collapsedLimit)
            : records.count
        UsageRows(
            records: Array(records.prefix(visibleCount)),
            onSelect: openAppDetail,
            subtitle: model.subtitle(for:)
        )
        if canExpand {
            showMoreButton(isExpanded: isExpanded, moreCount: expandedCount - collapsedLimit)
        }
        if canExpand, isExpanded.wrappedValue, records.count > expandedRowLimit {
            allApplicationsLink(count: records.count)
        }
    }

    private func allApplicationsLink(count: Int) -> some View {
        Button("在主窗口查看全部 \(count) 个应用") {
            openMainWindow(showsAppList: true)
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .pointingHandCursor()
        .focusable(false)
    }

    private func showMoreButton(isExpanded: Binding<Bool>, moreCount: Int) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                Text(isExpanded.wrappedValue ? "收起" : "再显示 \(moreCount) 个")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .interactiveHoverHighlight(cornerRadius: 6)
        .pointingHandCursor()
        .focusable(false)
        .padding(.horizontal, 4)
    }

    private func openMainWindow(showsAppList: Bool = false) {
        model.requestsMainWindowAppList = showsAppList
        ByteTraceAppDelegate.prepareMainWindow()
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 设置是主窗口里的独立页面：打开主窗口并进入设置页。
    private func openSettingsWindow() {
        model.requestsMainWindowSettings = true
        ByteTraceAppDelegate.prepareMainWindow()
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func openAppDetail(_ appKey: String) {
        model.openAppDetail(appKey)
        ByteTraceAppDelegate.prepareMainWindow()
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// 今日卡片的上行与下行占比条（上行在左），上行橙、下行蓝。
private struct DirectionShareBar: View {
    let downloadBytes: Int64
    let uploadBytes: Int64
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let filledWidth = totalBytes > 0 ? geometry.size.width : 0
            let gap: CGFloat = downloadBytes > 0 && uploadBytes > 0 && filledWidth > 4 ? 1.5 : 0
            let available = max(0, filledWidth - gap)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                HStack(spacing: gap) {
                    Rectangle()
                        .fill(TrafficColor.upload)
                        .frame(width: available * uploadFraction)
                    Rectangle()
                        .fill(TrafficColor.download)
                }
                .frame(width: filledWidth)
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private var totalBytes: Int64 {
        let result = downloadBytes.addingReportingOverflow(uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }

    private var uploadFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(uploadBytes) / Double(totalBytes))
    }
}

/// 最近 60 分钟每分钟一根柱子，最后一根代表当前分钟。右上角平时显示峰值，悬停时显示该分钟的时间与流量。
private struct HourSparkline: View {
    let points: [UsageTimelinePoint]

    @State private var hoveredIndex: Int?
    @State private var barsWidth: CGFloat = 0

    private static let slotCount = 60
    private static let maxBarHeight: CGFloat = 28
    private static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        let currentMinute = Self.currentMinute
        let values = slotValues(currentMinute: currentMinute)
        let peak = values.max() ?? 0
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近 1 小时")
                Spacer(minLength: 8)
                if let hoveredIndex, values.indices.contains(hoveredIndex) {
                    Text("\(minuteLabel(at: hoveredIndex, currentMinute: currentMinute)) · \(ByteTraceViewModel.formatBytes(values[hoveredIndex]))")
                        .foregroundStyle(.primary)
                } else if peak > 0 {
                    Text("峰值 \(ByteTraceViewModel.formatBytes(peak))/分钟")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color(at: index, value: values[index]))
                        .frame(height: barHeight(values[index], peak: peak))
                }
            }
            .frame(height: Self.maxBarHeight + 6, alignment: .bottom)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                barsWidth = width
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    guard barsWidth > 0 else { return }
                    let index = Int(location.x / barsWidth * CGFloat(Self.slotCount))
                    hoveredIndex = min(max(index, 0), Self.slotCount - 1)
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("最近 1 小时每分钟流量")
        .accessibilityValue(peak > 0 ? "峰值 \(ByteTraceViewModel.formatBytes(peak))/分钟" : "暂无流量")
    }

    private static var currentMinute: Date? {
        Calendar.autoupdatingCurrent.dateInterval(of: .minute, for: Date())?.start
    }

    private func minuteLabel(at index: Int, currentMinute: Date?) -> String {
        guard let currentMinute else { return "" }
        let date = currentMinute.addingTimeInterval(-Double(Self.slotCount - 1 - index) * 60)
        return Self.minuteFormatter.string(from: date)
    }

    /// 把分钟点映射到以当前分钟结尾的 60 个槽，没有数据的分钟记 0。
    private func slotValues(currentMinute: Date?) -> [Int64] {
        var values = Array(repeating: Int64(0), count: Self.slotCount)
        guard let currentMinute else {
            return values
        }
        for point in points {
            let minutesAgo = Int(currentMinute.timeIntervalSince(point.start) / 60)
            let index = Self.slotCount - 1 - minutesAgo
            guard values.indices.contains(index) else { continue }
            values[index] = point.totalBytes
        }
        return values
    }

    private func barHeight(_ value: Int64, peak: Int64) -> CGFloat {
        guard peak > 0, value > 0 else { return 2 }
        return max(3, Self.maxBarHeight * CGFloat(Double(value) / Double(peak)))
    }

    private func color(at index: Int, value: Int64) -> Color {
        let isHighlighted = hoveredIndex.map { $0 == index } ?? (index == Self.slotCount - 1)
        if value == 0 { return Color.primary.opacity(isHighlighted && hoveredIndex != nil ? 0.2 : 0.08) }
        return isHighlighted
            ? TrafficColor.download
            : TrafficColor.download.opacity(0.35)
    }
}

private struct UsageRows: View {
    let records: [DailyUsageRecord]
    let onSelect: (String) -> Void
    var subtitle: (DailyUsageRecord) -> String? = { _ in nil }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let duplicateNames = ByteTraceViewModel.duplicateDisplayNames(in: records)
        VStack(spacing: 0) {
            ForEach(records, id: \.appKey) { record in
                Button {
                    onSelect(record.appKey)
                } label: {
                    UsageRowView(
                        record: record,
                        showsPathHint: duplicateNames.contains(record.displayName)
                    )
                }
                .buttonStyle(.plain)
                .interactiveHoverHighlight(cornerRadius: 6)
                .pointingHandCursor()
                .focusable(false)
                // 运行过的程序和进程用途不占行内空间，悬停时与跳转提示一起显示。
                .help(help(for: record))
            }
        }
        .padding(.horizontal, 4)
        // 只在行集合本身变化（排名变动、增删应用）时做布局动画，字节数变化不触发。
        .animation(reduceMotion ? nil : .smooth, value: records.map(\.appKey))
    }

    private func help(for record: DailyUsageRecord) -> String {
        let action = "在主窗口查看 \(record.displayName)"
        guard let detail = subtitle(record) else { return action }
        return "\(detail)\n\(action)"
    }
}

private struct UsageRowView: View {
    let record: DailyUsageRecord
    var showsPathHint: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(record: record, size: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(record.displayName)
                        .lineLimit(1)
                        .layoutPriority(1)
                    // 同名进程只能靠路径区分，仍跟在名称后面显示。
                    if showsPathHint, let path = record.bundlePath ?? record.executablePath {
                        Text(ByteTraceViewModel.abbreviatedPath(path))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 6)
                    // 与主窗口列表同理，逐行数字滚动动画会让整个面板持续重绘；
                    // 顶部总量只有一个，仍保留动画。
                    Text(ByteTraceViewModel.formatBytes(Self.totalBytes(of: record)))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .fixedSize()
                }

                // 不再画占比条：每行一条长条在列表里叠成条纹，上下行数字已能说明方向。
                // 箭头沿用今日卡片占比条的方向配色。
                Text(
                    "\(Text("↑").foregroundStyle(TrafficColor.upload)) \(ByteTraceViewModel.formatBytes(record.uploadBytes))  \(Text("↓").foregroundStyle(TrafficColor.download)) \(ByteTraceViewModel.formatBytes(record.downloadBytes))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    static func totalBytes(of record: DailyUsageRecord) -> Int64 {
        let result = record.downloadBytes.addingReportingOverflow(record.uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }
}

/// 标题不重复顶部状态；说明按状态区分，统计停止或出错时不提示「再等几秒」。
private struct EmptyTrafficView: View {
    let status: MonitorStatus

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("今天还没有流量记录")
                .font(.body.weight(.medium))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var detail: String {
        switch status {
        case .starting, .baseline, .collecting:
            return "再等几秒，今天的应用流量就会显示在这里。"
        case .stopped:
            return "开始统计后，应用流量会显示在这里。"
        case .reconnecting, .incompatible, .failed:
            return "统计恢复后，应用流量会显示在这里。"
        }
    }
}

extension MonitorStatus {
    var title: String {
        switch self {
        case .stopped: return "统计已停止"
        case .starting: return "正在启动统计"
        case .baseline: return "正在读取系统流量"
        case .collecting: return "正在统计"
        case .reconnecting: return "正在自动恢复"
        case .incompatible: return "当前系统版本不受支持"
        case .failed: return "统计不可用"
        }
    }

    var detail: String {
        switch self {
        case .stopped: return "可从这里重新开始统计。"
        case .starting: return "正在连接系统流量统计。"
        case .baseline: return "刚启动的前几秒不计入统计。"
        case .collecting: return "流量数据每约 5 秒保存一次。"
        case .reconnecting: return "统计中断，正在自动恢复。"
        case .incompatible: return "已暂停统计，需要更新 ByteTrace 以支持当前 macOS 版本。"
        case .failed: return "请查看错误信息，修复后重新开始。"
        }
    }

    var tint: Color {
        switch self {
        case .stopped: return .secondary
        case .starting, .baseline, .reconnecting: return .orange
        case .collecting: return .green
        case .incompatible, .failed: return .red
        }
    }
}
