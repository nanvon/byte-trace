import AppKit
import ByteTraceCore
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: ByteTraceViewModel

    @Environment(\.openWindow) private var openWindow
    @State private var isProxyExpanded = false
    @State private var isSystemExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCard
                    statusCard
                    usageContent
                }
                .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 390, height: 560)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ByteTrace")
                    .font(.headline)
                Text("今日 · \(model.dayKey)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("刷新今日统计")

            Button {
                model.requestedMainWindowPage = .overview
                openWindow(id: "main")
            } label: {
                Image(systemName: "macwindow")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("打开主窗口")

            Button {
                model.requestedMainWindowPage = .settings
                openWindow(id: "main")
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日总量")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ByteTraceViewModel.formatBytes(model.todayTotals.totalBytes))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }

            HStack(spacing: 0) {
                MetricView(
                    title: "下载",
                    value: model.todayTotals.downloadBytes,
                    symbolName: "arrow.down",
                    tint: .blue
                )
                Divider()
                    .frame(height: 30)
                    .padding(.horizontal, 14)
                MetricView(
                    title: "上传",
                    value: model.todayTotals.uploadBytes,
                    symbolName: "arrow.up",
                    tint: .orange
                )
            }
        }
        .padding(14)
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
        }
        .padding(12)
        .background(
            model.status.tint.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    @ViewBuilder
    private var usageContent: some View {
        if model.records.isEmpty {
            EmptyTrafficView()
        } else {
            UsageSection(title: "应用与未知进程", records: model.applicationRecords)

            if !model.proxyRecords.isEmpty {
                DisclosureGroup(isExpanded: $isProxyExpanded) {
                    UsageRows(records: model.proxyRecords)
                } label: {
                    GroupLabel(
                        title: "代理运输流量",
                        count: model.proxyRecords.count,
                        symbolName: "arrow.triangle.2.circlepath",
                        tint: .purple
                    )
                }
            }

            if model.showsSystemProcesses, !model.systemRecords.isEmpty {
                DisclosureGroup(isExpanded: $isSystemExpanded) {
                    UsageRows(records: model.systemRecords)
                } label: {
                    GroupLabel(
                        title: "系统与后台进程",
                        count: model.systemRecords.count,
                        symbolName: "gearshape.2",
                        tint: .secondary
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.status.tint)
                .frame(width: 7, height: 7)
            Text(model.status.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("仅保存在本机")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button {
                model.shutdown()
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("退出 ByteTrace")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(ByteTraceViewModel.formatBytes(value))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UsageSection: View {
    let title: String
    let records: [DailyUsageRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("\(records.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if records.isEmpty {
                Text("暂无应用流量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                UsageRows(records: records)
            }
        }
    }
}

private struct UsageRows: View {
    let records: [DailyUsageRecord]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(records, id: \.appKey) { record in
                UsageRowView(record: record)
                if record.appKey != records.last?.appKey {
                    Divider()
                        .padding(.leading, 42)
                }
            }
        }
        .padding(.horizontal, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct UsageRowView: View {
    let record: DailyUsageRecord

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
            }

            Spacer(minLength: 6)

            Text(ByteTraceViewModel.formatBytes(totalBytes))
                .font(.callout.weight(.medium))
                .monospacedDigit()
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
            Text("正在建立统计基线")
                .font(.subheadline.weight(.medium))
            Text("完成首个采样周期后，今日应用流量会显示在这里。")
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
        case .starting: return "正在启动采集"
        case .baseline: return "正在建立统计基线"
        case .collecting: return "正在统计"
        case .reconnecting: return "正在重连"
        case .incompatible: return "系统格式不兼容"
        case .failed: return "采集不可用"
        }
    }

    var detail: String {
        switch self {
        case .stopped: return "可从这里重新开始采集。"
        case .starting: return "正在连接系统流量统计。"
        case .baseline: return "首帧只用于建立基线，不会计入今日流量。"
        case .collecting: return "应用流量每约 5 秒写入本机数据库。"
        case .reconnecting: return "nettop 已退出，将按退避策略重新启动。"
        case .incompatible: return "已暂停入账，请检查当前 macOS 的 nettop 格式。"
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
