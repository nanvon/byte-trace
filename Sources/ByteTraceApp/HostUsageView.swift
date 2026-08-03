import ByteTraceCore
import SwiftUI

struct HostUsageView: View {
    @ObservedObject var model: ByteTraceViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rangePicker
                    titleBlock

                    if let result = model.hostUsageResult {
                        coverageSummary(result.coverage)
                        ranking(result.rows)
                    } else if !model.enableConnectionCollector {
                        disabledState
                    } else {
                        unavailableState
                    }
                }
                .padding(24)
            }
            .navigationTitle("可见主机名")
            .toolbar {
                ToolbarItem {
                    Button {
                        model.refresh()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .pointingHandCursor()
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
        .pointingHandCursor()
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("可见主机名")
                    .font(.title2.weight(.semibold))
                Text("实验数据 · 部分可见")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.12), in: Capsule())
            }
            Text("只展示连接级 nettop 直接观察到的主机名；IP-only、缺失名称和无法归属的流量统一计入“无法识别/其他”。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func coverageSummary(_ coverage: NettopHostUsageCoverage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                HostUsageMetricCard(
                    title: "可见主机名",
                    value: coverage.visibleHostnameBytes,
                    symbolName: "globe",
                    tint: .accentColor
                )
                HostUsageMetricCard(
                    title: "无法识别/其他",
                    value: coverage.unrecognizedBytes,
                    symbolName: "questionmark.circle",
                    tint: .secondary
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("覆盖率")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(percent(coverage.formalVisibilityRatio))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                ProgressView(value: min(max(coverage.formalVisibilityRatio ?? 0, 0), 1))
                    .tint(.accentColor)
                HStack {
                    Text("可识别字节 / 正式应用总量")
                    Spacer()
                    Text("连接观测内可见 \(percent(coverage.observedVisibilityRatio))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func ranking(_ rows: [NettopHostUsageRank]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("主机名排行")
                    .font(.title3.weight(.semibold))
                Text("\(rows.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if rows.isEmpty {
                Text("当前时间范围内暂无可见主机名数据")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HostUsageRow(row: row)
                        if index < rows.count - 1 {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var disabledState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "globe.badge.minus")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("连接级采集未启用")
                .font(.headline)
            Text("该实验功能默认关闭。可在设置页开启，但会额外运行一个连接级 nettop 进程，显著增加 CPU 与耗电。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("本地统计存储不可用")
                .font(.headline)
            Text("可见主机名实验数据需要本地数据库支持。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func percent(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return ratio.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct HostUsageMetricCard: View {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct HostUsageRow: View {
    let row: NettopHostUsageRank

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.isVisibleHostname ? "globe" : "questionmark.circle")
                .font(.title3)
                .foregroundStyle(row.isVisibleHostname ? Color.accentColor : Color.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text("↓ \(ByteTraceViewModel.formatBytes(row.downloadBytes))")
                    Text("↑ \(ByteTraceViewModel.formatBytes(row.uploadBytes))")
                    Text("\(row.connectionCount) 连接")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Spacer(minLength: 8)

            Text(ByteTraceViewModel.formatBytes(row.totalBytes))
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
