import AppKit
import ByteTraceCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: ByteTraceViewModel
    private let updater = AppUpdater.shared

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("ByteTrace.menuBar.proxySectionExpanded") private var isProxyExpanded = false
    @AppStorage("ByteTrace.menuBar.systemSectionExpanded") private var isSystemExpanded = true
    @State private var showsMoreApplications = false
    @State private var showsMoreSystemProcesses = false
    @State private var showsMoreProxyProcesses = false
    /// 滚动内容的实际高度；初值是常见内容的估计，避免首帧高度为 0。
    @State private var contentHeight: CGFloat = 560

    private let collapsedRowLimit = 5
    private let expandedRowLimit = 15
    private let collapsedSectionRowLimit = 3

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
                openMainWindow(page: .overview)
            }
            headerButton(symbolName: "gearshape", label: "设置") {
                openMainWindow(page: .settings)
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
                    Text("代理流量")
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
                    expandableRows(
                        applications,
                        collapsedLimit: collapsedRowLimit,
                        isExpanded: $showsMoreApplications,
                        page: .applications,
                        noun: "个应用"
                    )
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

    private var hasSeparateSection: Bool {
        !model.proxyRecords.isEmpty || (model.showsSystemProcesses && !model.systemRecords.isEmpty)
    }

    private var separateSection: some View {
        VStack(spacing: 0) {
            if model.showsSystemProcesses, !model.systemRecords.isEmpty {
                CollapsibleSectionCard(
                    symbolName: "desktopcomputer",
                    tint: .secondary,
                    title: "系统与后台进程",
                    subtitle: "\(model.systemRecords.count) 个进程",
                    bytes: systemTotalBytes,
                    isExpanded: $isSystemExpanded
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        expandableRows(
                            model.systemRecords,
                            collapsedLimit: collapsedSectionRowLimit,
                            isExpanded: $showsMoreSystemProcesses,
                            page: .system,
                            noun: "个进程"
                        )
                    }
                    .padding(.bottom, 4)
                }
            }
            if !model.proxyRecords.isEmpty, model.showsSystemProcesses, !model.systemRecords.isEmpty {
                Divider()
                    .padding(.leading, 44)
            }
            if !model.proxyRecords.isEmpty {
                CollapsibleSectionCard(
                    symbolName: "arrow.triangle.2.circlepath",
                    tint: TrafficColor.proxy,
                    title: "代理传输",
                    subtitle: "\(proxyNames) · 不计入总量",
                    bytes: model.proxyTotals.totalBytes,
                    isExpanded: $isProxyExpanded
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        expandableRows(
                            model.proxyRecords,
                            collapsedLimit: collapsedSectionRowLimit,
                            isExpanded: $showsMoreProxyProcesses,
                            page: .proxy,
                            noun: "个代理进程"
                        )
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .cardSurface()
    }

    /// 应用、系统进程、代理传输三处共用：折叠时列出前几行，展开到 `expandedRowLimit` 行，
    /// 仍有剩余时给出跳转主窗口对应页面的入口。折叠后只差一行时直接全部列出，不为一行单独放按钮。
    @ViewBuilder
    private func expandableRows(
        _ records: [DailyUsageRecord],
        collapsedLimit: Int,
        isExpanded: Binding<Bool>,
        page: MainWindowPage,
        noun: String
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
            sectionLink(count: records.count, page: page, noun: noun)
        }
    }

    private func sectionLink(count: Int, page: MainWindowPage, noun: String) -> some View {
        Button("在主窗口查看全部 \(count) \(noun)") {
            openMainWindow(page: page)
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .pointingHandCursor()
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
        .padding(.horizontal, 4)
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
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func openAppDetail(_ appKey: String) {
        model.openAppDetail(appKey)
        ByteTraceAppDelegate.prepareMainWindow()
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// 上行与下行的占比条（上行在左）。今日卡片填满整条；列表行按 `fraction`（相对第一名）截取长度，
/// 同一行里仍按上行橙、下行蓝拆分，方向不用读数字也能看出来。
private struct DirectionShareBar: View {
    let downloadBytes: Int64
    let uploadBytes: Int64
    /// 0...1，填充部分占轨道的比例。
    var fraction: Double = 1
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let filledWidth = geometry.size.width * clampedFraction
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

    private var clampedFraction: Double {
        guard totalBytes > 0, fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
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
                Text("最近 1 小时 · 每分钟")
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

            HStack {
                Text("60 分钟前")
                Spacer()
                Text("现在")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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
    var subtitle: (DailyUsageRecord) -> String? = { _ in nil }

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
                        showsPathHint: duplicateNames.contains(record.displayName),
                        subtitle: subtitle(record)
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
    var subtitle: String?

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
                    DirectionShareBar(
                        downloadBytes: record.downloadBytes,
                        uploadBytes: record.uploadBytes,
                        fraction: share,
                        height: 4
                    )
                    // 箭头沿用占比条的方向配色，对应关系一眼可见。
                    Text(
                        "\(Text("↑").foregroundStyle(TrafficColor.upload)) \(ByteTraceViewModel.formatBytes(record.uploadBytes))  \(Text("↓").foregroundStyle(TrafficColor.download)) \(ByteTraceViewModel.formatBytes(record.downloadBytes))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
