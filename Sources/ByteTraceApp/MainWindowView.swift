import AppKit
import Charts
import ByteTraceCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var model: ByteTraceViewModel
    @State private var selection: MainWindowPage = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("概览", systemImage: "chart.bar.xaxis")
                    .tag(MainWindowPage.overview)
                Label("可见主机名", systemImage: "globe")
                    .tag(MainWindowPage.hostUsage)
                Label("设置", systemImage: "gearshape")
                    .tag(MainWindowPage.settings)
            }
            .listStyle(.sidebar)
            .navigationTitle("ByteTrace")
        } detail: {
            switch selection {
            case .overview:
                MainOverviewView(model: model)
            case .hostUsage:
                HostUsageView(model: model)
            case .settings:
                SettingsView(model: model)
            }
        }
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 620, idealHeight: 720)
        .onAppear {
            selection = model.requestedMainWindowPage
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .onChange(of: model.requestedMainWindowPage) { _, page in
            selection = page
        }
    }
}

private struct MainOverviewView: View {
    @ObservedObject var model: ByteTraceViewModel

    private var visibleRecords: [DailyUsageRecord] {
        model.rangeRecords.filter {
            $0.category != .proxyTransport
                && (model.showsSystemProcesses || $0.category != .systemProcess)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rangePicker
                    summary
                    timeline
                    applicationList(records: visibleRecords)
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
                    Text("细粒度统计会在采集运行后逐步积累。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 42)
            } else {
                Chart(model.rangeTimeline) { point in
                    AreaMark(
                        x: .value("时间", point.start),
                        y: .value("总量", point.totalBytes)
                    )
                    .foregroundStyle(.blue.opacity(0.16))

                    LineMark(
                        x: .value("时间", point.start),
                        y: .value("总量", point.totalBytes)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 220)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func applicationList(records: [DailyUsageRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("应用流量")
                    .font(.title3.weight(.semibold))
                Text("\(records.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if records.isEmpty {
                Text("当前时间范围内暂无应用流量")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                VStack(spacing: 0) {
                    ForEach(records, id: \.appKey) { record in
                        NavigationLink(value: record.appKey) {
                            MainUsageRow(record: record)
                        }
                        .buttonStyle(.plain)
                        if record.appKey != records.last?.appKey {
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
                    AxisMarks(position: .leading)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MainUsageRow: View {
    let record: DailyUsageRecord

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
            }

            Spacer(minLength: 8)

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
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
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
