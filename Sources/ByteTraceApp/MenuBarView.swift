import AppKit
import ByteTraceCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: ByteTraceViewModel

    @Environment(\.openWindow) private var openWindow
    @AppStorage("ByteTrace.menuBar.applicationExpanded") private var isApplicationExpanded = true
    @AppStorage("ByteTrace.menuBar.proxyExpanded") private var isProxyExpanded = true
    @AppStorage("ByteTrace.menuBar.systemExpanded") private var isSystemExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCard
                    if model.status != .collecting || model.lastError != nil {
                        statusCard
                    }
                    usageContent
                }
                .padding(16)
            }
        }
        .frame(width: 390, height: 672)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ByteTrace")
                    .font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.status.tint)
                        .frame(width: 7, height: 7)
                    Text(model.status.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button {
                openMainWindow(page: .overview)
            } label: {
                Image(systemName: "macwindow")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ByteTraceActionButtonStyle())
            .pointingHandCursor()
            .accessibilityLabel("打开主窗口")
            .help("打开主窗口")

            Button {
                openMainWindow(page: .settings)
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ByteTraceActionButtonStyle())
            .pointingHandCursor()
            .accessibilityLabel("设置")
            .help("设置")

            Button {
                model.shutdown()
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(ByteTraceActionButtonStyle())
            .pointingHandCursor()
            .accessibilityLabel("退出 ByteTrace")
            .help("退出 ByteTrace")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日总量")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteTraceViewModel.formatBytes(model.todayTotals.totalBytes))
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth, value: model.todayTotals.totalBytes)
            }

            HStack(spacing: 0) {
                MetricView(
                    title: "下载",
                    value: model.todayTotals.downloadBytes,
                    symbolName: "arrow.down",
                    tint: .blue
                )
                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 12)
                MetricView(
                    title: "上传",
                    value: model.todayTotals.uploadBytes,
                    symbolName: "arrow.up",
                    tint: .orange
                )
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: model.status.symbolName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(model.status.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.status.title)
                    .font(.subheadline.weight(.medium))
                if let lastError = model.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(model.status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(model.isCollecting ? "停止" : "开始") {
                if model.isCollecting {
                    model.stop()
                } else {
                    model.start()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
        }
        .padding(12)
        .background(
            model.status.tint.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private let topRowLimit = 10

    @ViewBuilder
    private var usageContent: some View {
        if model.records.isEmpty {
            EmptyTrafficView()
        } else {
            applicationSection

            if !model.proxyRecords.isEmpty {
                DisclosureGroup(isExpanded: $isProxyExpanded) {
                    UsageRows(records: Array(model.proxyRecords.prefix(topRowLimit)))
                } label: {
                    GroupLabel(
                        title: "代理运输流量",
                        count: model.proxyRecords.count,
                        symbolName: "arrow.triangle.2.circlepath",
                        tint: .purple
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .interactiveHoverHighlight()
                    .pointingHandCursor()
                }
            }

            if model.showsSystemProcesses, !model.systemRecords.isEmpty {
                DisclosureGroup(isExpanded: $isSystemExpanded) {
                    UsageRows(records: Array(model.systemRecords.prefix(topRowLimit)))
                } label: {
                    GroupLabel(
                        title: "系统与后台进程",
                        count: model.systemRecords.count,
                        symbolName: "gearshape.2",
                        tint: .secondary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .interactiveHoverHighlight()
                    .pointingHandCursor()
                }
            }
        }
    }

    private var applicationSection: some View {
        DisclosureGroup(isExpanded: $isApplicationExpanded) {
            if model.applicationRecords.isEmpty {
                Text("暂无应用流量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                UsageRows(records: Array(model.applicationRecords.prefix(topRowLimit)))
            }
        } label: {
            GroupLabel(
                title: "应用流量",
                count: model.applicationRecords.count,
                symbolName: "chart.bar.xaxis",
                tint: .accentColor
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .interactiveHoverHighlight()
            .pointingHandCursor()
        }
    }

    private func openMainWindow(page: MainWindowPage) {
        model.requestedMainWindowPage = page
        ByteTraceAppDelegate.prepareMainWindow()
        openWindow(id: "main")
    }

}

private struct MetricView: View {
    let title: String
    let value: Int64
    let symbolName: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbolName)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(ByteTraceViewModel.formatBytes(value))
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageRows: View {
    let records: [DailyUsageRecord]

    var body: some View {
        let duplicateNames = ByteTraceViewModel.duplicateDisplayNames(in: records)
        VStack(spacing: 0) {
            ForEach(records, id: \.appKey) { record in
                UsageRowView(
                    record: record,
                    showsPathHint: duplicateNames.contains(record.displayName)
                )
                if record.appKey != records.last?.appKey {
                    Divider()
                        .padding(.leading, 42)
                }
            }
        }
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.smooth, value: records)
    }
}

private struct UsageRowView: View {
    let record: DailyUsageRecord
    var showsPathHint: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            appIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("↓ \(ByteTraceViewModel.formatBytes(record.downloadBytes))")
                    Text("↑ \(ByteTraceViewModel.formatBytes(record.uploadBytes))")
                }
                .font(.caption2)
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

            Spacer(minLength: 6)

            Text(ByteTraceViewModel.formatBytes(totalBytes))
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: totalBytes)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var totalBytes: Int64 {
        let result = record.downloadBytes.addingReportingOverflow(record.uploadBytes)
        return result.overflow ? Int64.max : result.partialValue
    }

    @ViewBuilder
    private var appIcon: some View {
        if let path = record.bundlePath ?? record.executablePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
        } else {
            Image(systemName: "app.dashed")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
}

private struct GroupLabel: View {
    let title: String
    let count: Int
    let symbolName: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title)
                .font(.subheadline.weight(.medium))
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }
}

private struct EmptyTrafficView: View {
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("正在读取系统流量")
                .font(.subheadline.weight(.medium))
            Text("再等几秒，今天的应用流量就会显示在这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

private extension MonitorStatus {
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

    var symbolName: String {
        switch self {
        case .stopped: return "pause.circle"
        case .starting: return "arrow.triangle.2.circlepath"
        case .baseline: return "circle.dashed"
        case .collecting: return "waveform.path.ecg"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .incompatible: return "exclamationmark.triangle"
        case .failed: return "xmark.octagon"
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
