import AppKit
import UniformTypeIdentifiers
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ByteTraceViewModel
    @State private var isShowingClearConfirmation = false
    @State private var isShowingHostClearConfirmation = false
    @State private var pendingRetentionPolicy: UsageRetentionPolicy?
    @State private var exportMessage: String?
    @State private var exportedFileURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section("采集") {
                    Toggle(
                        "显示系统与后台进程",
                        isOn: $model.showsSystemProcesses
                    )
                    Toggle(
                        "登录时启动",
                        isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: { model.setLaunchAtLogin($0) }
                        )
                    )
                }

                Section("本地存储") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("数据库位置")
                            .font(.subheadline)
                        Text(model.databaseURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Button {
                        model.revealDatabase()
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }

                    Button {
                        exportCurrentRange()
                    } label: {
                        Label("导出当前范围 JSON", systemImage: "square.and.arrow.up")
                    }

                    if let exportMessage {
                        HStack(spacing: 8) {
                            Text(exportMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let exportedFileURL {
                                Spacer()
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([exportedFileURL])
                                }
                                .font(.caption)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        isShowingClearConfirmation = true
                    } label: {
                        Label("清空全部统计", systemImage: "trash")
                    }
                }

                Section("细粒度统计") {
                    Picker(
                        "分钟级数据保留",
                        selection: Binding(
                            get: { model.usageRetentionPolicy },
                            set: { policy in
                                guard policy != model.usageRetentionPolicy else { return }
                                if policy.interval != nil {
                                    pendingRetentionPolicy = policy
                                } else {
                                    model.usageRetentionPolicy = policy
                                }
                            }
                        )
                    ) {
                        ForEach(UsageRetentionPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }

                    if let stats = model.bucketStats, stats.bucketCount > 0 {
                        LabeledContent("已记录的时间点", value: "\(stats.bucketCount)")
                        LabeledContent(
                            "最早记录",
                            value: formattedDate(stats.earliestBucket)
                        )
                        LabeledContent(
                            "最新记录",
                            value: formattedDate(stats.latestBucket)
                        )
                    } else {
                        Text("尚未积累分钟级统计数据，开始统计后会逐步显示最近时间范围和趋势。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("默认不自动清理。启用保留周期后，只会删除超过周期的分钟级数据，每日汇总和应用信息不受影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("可见主机名实验") {
                    Toggle(
                        "启用连接级采集（实验）",
                        isOn: $model.enableConnectionCollector
                    )
                    Text("开启会额外运行一个统计进程，明显增加 CPU 与耗电，默认关闭。关闭后已收集的历史数据仍保留，可手动清空。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("该实验数据与正式应用统计分开保存，清理这里不会影响应用流量统计。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        isShowingHostClearConfirmation = true
                    } label: {
                        Label("清空主机名实验数据", systemImage: "globe.badge.chevron.backward")
                    }
                }

                Section("关于 ByteTrace") {
                    LabeledContent("数据源", value: "系统 nettop")
                    LabeledContent("统计口径", value: "应用逻辑流量")
                    Text("代理运输流量会单独显示，不计入今日应用总量。所有数据仅保存在本机。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onAppear {
                model.refreshBucketStats()
            }
        }
        .confirmationDialog(
            "确定清空全部统计？",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空统计", role: .destructive) {
                model.clearAllData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会删除本机保存的每日应用流量和采集诊断记录，不能撤销。")
        }
        .confirmationDialog(
            "确定清空主机名实验数据？",
            isPresented: $isShowingHostClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空主机名数据", role: .destructive) {
                model.clearHostUsageData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作只删除连接级主机名实验数据，不影响正式应用统计和日汇总。")
        }
        .confirmationDialog(
            "启用分钟级数据保留？",
            isPresented: Binding(
                get: { pendingRetentionPolicy != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingRetentionPolicy = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("启用并清理", role: .destructive) {
                if let pendingRetentionPolicy {
                    model.usageRetentionPolicy = pendingRetentionPolicy
                }
                pendingRetentionPolicy = nil
            }
            Button("取消", role: .cancel) {
                pendingRetentionPolicy = nil
            }
        } message: {
            Text("将立即删除超过所选周期的分钟时间桶。日汇总和应用信息不受影响，删除后不能恢复。")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Self.dateFormatter.string(from: date)
    }

    private func exportCurrentRange() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "ByteTrace-\(model.selectedRange.rawValue).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try model.exportCurrentRange(to: url)
                exportMessage = "已导出：\(url.lastPathComponent)"
                exportedFileURL = url
            } catch {
                exportMessage = "导出失败：\(error.localizedDescription)"
                exportedFileURL = nil
            }
        }
    }
}
