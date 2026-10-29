import AppKit
import ByteTraceCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: ByteTraceViewModel
    private let updater = AppUpdater.shared

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("ByteTrace.menuBar.proxySectionExpanded") private var isProxyExpanded = false
    @AppStorage("ByteTrace.menuBar.systemSectionExpanded") private var isSystemExpanded = false
    @State private var showsMoreApplications = false
    /// 滚动内容的实际高度；初值是常见内容的估计，避免首帧高度为 0。
    @State private var contentHeight: CGFloat = 560

    private let collapsedRowLimit = 8
    private let expandedRowLimit = 15
    private let sectionRowLimit = 5

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
        }
        .frame(width: 390)
        .background(Color(nsColor: .windowBackgroundColor))
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
        return max(320, visibleHeight - 54 - 40)
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
                openMainWindow(page: .overview)
            }
            headerButton(symbolName: "gearshape", label: "设置") {
                openMainWindow(page: .settings)
            }
            headerButton(
                symbolName: updater.hasUpdate ? "arrow.down.circle.fill" : "arrow.down.circle",
                label: updater.hasUpdate || updater.isWorking ? "查看更新" : "检查更新"
            ) {
                updater.checkForUpdates()
            }
            headerButton(symbolName: "power", label: "退出 ByteTrace") {
                model.shutdown()
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
        .accessibilityLabel(label)
        .help(label)
    }

    /// 正常统计时只在顶部显示一行状态；停止或出错时补充原因并给出开始/停止操作。
    private var showsCollectionControl: Bool {
        model.status != .collecting || model.lastError != nil
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.status.title)
                    .font(.subheadline.weight(.medium))
                Text(model.lastError ?? model.status.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(model.isCollecting ? "停止" : "开始") {
                if model.isCollecting {
                    model.stop()
                } else {
                    model.start()
                }
            }
            .controlSize(.small)
            .pointingHandCursor()
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
                Text(model.todayDisplayText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            totalText

            DirectionShareBar(totals: totals)

            HStack(spacing: 18) {
                legendValue(color: TrafficColor.download, title: "下行", bytes: totals.downloadBytes)
                legendValue(color: TrafficColor.upload, title: "上行", bytes: totals.uploadBytes)
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
            EmptyTrafficView()
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
                    openMainWindow(page: .applications)
                }
                .buttonStyle(.link)
                .font(.callout)
                .pointingHandCursor()
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
                    UsageRows(
                        records: Array(applications.prefix(applicationRowLimit)),
                        onSelect: openAppDetail
                    )
                    if applications.count > collapsedRowLimit {
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                                showsMoreApplications.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: showsMoreApplications ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                Text(showsMoreApplications ? "收起" : "显示更多")
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
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.vertical, 4)
            .cardSurface()

            if hasSeparateSection {
                separateSection
                    .padding(.top, 10)
            }
        }
    }

    private var applicationRowLimit: Int {
        showsMoreApplications ? expandedRowLimit : collapsedRowLimit
    }

    private var hasSeparateSection: Bool {
        !model.proxyRecords.isEmpty || (model.showsSystemProcesses && !model.systemRecords.isEmpty)
    }

    private var separateSection: some View {
        VStack(spacing: 0) {
            if !model.proxyRecords.isEmpty {
                CollapsibleSectionCard(
                    symbolName: "arrow.triangle.2.circlepath",
                    tint: TrafficColor.proxy,
                    title: "代理传输",
                    subtitle: "\(proxyNames) · 单独展示，不计入总量",
                    bytes: model.proxyTotals.totalBytes,
                    isExpanded: $isProxyExpanded
                ) {
                    sectionRows(model.proxyRecords, page: .proxy, noun: "个代理进程")
                }
            }
            if !model.proxyRecords.isEmpty, model.showsSystemProcesses, !model.systemRecords.isEmpty {
                Divider()
                    .padding(.leading, 44)
            }
            if model.showsSystemProcesses, !model.systemRecords.isEmpty {
                CollapsibleSectionCard(
                    symbolName: "desktopcomputer",
                    tint: .secondary,
                    title: "系统与后台进程",
                    subtitle: "\(model.systemRecords.count) 个进程",
                    bytes: systemTotalBytes,
                    isExpanded: $isSystemExpanded
                ) {
                    sectionRows(model.systemRecords, page: .system, noun: "个进程")
                }
            }
        }
        .cardSurface()
    }

    /// 展开后列出前几个进程；超出时给出跳转主窗口对应页面的入口。
    private func sectionRows(
        _ records: [DailyUsageRecord],
        page: MainWindowPage,
        noun: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageRows(
                records: Array(records.prefix(sectionRowLimit)),
                onSelect: openAppDetail
            )
            if records.count > sectionRowLimit {
                Button("在主窗口查看全部 \(records.count) \(noun)") {
                    openMainWindow(page: page)
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .pointingHandCursor()
            }
        }
        .padding(.bottom, 4)
    }

    private var proxyNames: String {
        let names = model.proxyRecords.prefix(2).map(\.displayName)
        let suffix = model.proxyRecords.count > 2 ? " 等" : ""
        return names.joined(separator: "、") + suffix
    }

    private var systemTotalBytes: Int64 {
        model.systemRecords.reduce(Int64(0)) { partial, record in
            let total = UsageRowView.totalBytes(of: record)
            let result = partial.addingReportingOverflow(total)
            return result.overflow ? Int64.max : result.partialValue
        }
    }

    private func openMainWindow(page: MainWindowPage) {
        model.requestedMainWindowPage = page
        ByteTraceAppDelegate.prepareMainWindow()
        openWindow(id: "main")
    }

    private func openAppDetail(_ appKey: String) {
        model.openAppDetail(appKey)
        ByteTraceAppDelegate.prepareMainWindow()
        openWindow(id: "main")
    }
}

/// 下行与上行的占比条。
private struct DirectionShareBar: View {
    let totals: UsageTotals

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = totals.downloadBytes > 0 && totals.uploadBytes > 0 ? 2 : 0
            let available = max(0, geometry.size.width - gap)
            HStack(spacing: gap) {
                if totals.totalBytes > 0 {
                    Capsule()
                        .fill(TrafficColor.download)
                        .frame(width: available * downloadFraction)
                    Capsule()
                        .fill(TrafficColor.upload)
                } else {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var downloadFraction: Double {
        guard totals.totalBytes > 0 else { return 0 }
        return min(1, Double(totals.downloadBytes) / Double(totals.totalBytes))
    }
}

/// 最近 60 分钟每分钟一根柱子，最后一根代表当前分钟。
private struct HourSparkline: View {
    let points: [UsageTimelinePoint]

    private static let slotCount = 60
    private static let maxBarHeight: CGFloat = 28

    var body: some View {
        let values = slotValues
        let peak = values.max() ?? 0
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color(at: index, value: values[index]))
                        .frame(height: barHeight(values[index], peak: peak))
                }
            }
            .frame(height: Self.maxBarHeight + 6, alignment: .bottom)

            HStack {
                Text("60 分钟前")
                Spacer()
                Text("最近 1 小时 · 每分钟")
                Spacer()
                Text("现在")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("最近 1 小时每分钟流量")
    }

    /// 把分钟点映射到以当前分钟结尾的 60 个槽，没有数据的分钟记 0。
    private var slotValues: [Int64] {
        var values = Array(repeating: Int64(0), count: Self.slotCount)
        let calendar = Calendar.autoupdatingCurrent
        guard let currentMinute = calendar.dateInterval(of: .minute, for: Date())?.start else {
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
        if value == 0 { return Color.primary.opacity(0.08) }
        return index == Self.slotCount - 1
            ? TrafficColor.download
            : TrafficColor.download.opacity(0.35)
    }
}

/// 代理传输、系统与后台进程的可折叠分组：标题行显示汇总，点击展开具体进程。
private struct CollapsibleSectionCard<Content: View>: View {
    let symbolName: String
    let tint: Color
    let title: String
    let subtitle: String
    let bytes: Int64
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(ByteTraceViewModel.formatBytes(bytes))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .interactiveHoverHighlight(cornerRadius: 12)
            .pointingHandCursor()
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            .help(isExpanded ? "收起\(title)" : "展开\(title)")

            if isExpanded {
                content()
                    .transition(.opacity)
            }
        }
    }
}

private struct UsageRows: View {
    let records: [DailyUsageRecord]
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let duplicateNames = ByteTraceViewModel.duplicateDisplayNames(in: records)
        let largest = records.map(UsageRowView.totalBytes(of:)).max() ?? 0
        VStack(spacing: 0) {
            ForEach(records, id: \.appKey) { record in
                Button {
                    onSelect(record.appKey)
                } label: {
                    UsageRowView(
                        record: record,
                        share: largest > 0
                            ? Double(UsageRowView.totalBytes(of: record)) / Double(largest)
                            : 0,
                        showsPathHint: duplicateNames.contains(record.displayName)
                    )
                }
                .buttonStyle(.plain)
                .interactiveHoverHighlight(cornerRadius: 6)
                .pointingHandCursor()
                .help("在主窗口查看 \(record.displayName)")
            }
        }
        .padding(.horizontal, 4)
        // 只在行集合本身变化（排名变动、增删应用）时做布局动画，字节数变化不触发。
        .animation(reduceMotion ? nil : .smooth, value: records.map(\.appKey))
    }
}

private struct UsageRowView: View {
    let record: DailyUsageRecord
    let share: Double
    var showsPathHint: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(record: record, size: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.displayName)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    // 与主窗口列表同理，逐行数字滚动动画会让整个面板持续重绘；
                    // 顶部总量只有一个，仍保留动画。
                    Text(ByteTraceViewModel.formatBytes(Self.totalBytes(of: record)))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    UsageShareBar(fraction: share, height: 4)
                    Text(
                        "↓ \(ByteTraceViewModel.formatBytes(record.downloadBytes))  ↑ \(ByteTraceViewModel.formatBytes(record.uploadBytes))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
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

private struct EmptyTrafficView: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("正在读取系统流量")
                .font(.body.weight(.medium))
            Text("再等几秒，今天的应用流量就会显示在这里。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
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
