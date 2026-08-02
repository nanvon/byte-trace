import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ByteTraceViewModel
    @State private var isShowingClearConfirmation = false

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

                    Button(role: .destructive) {
                        isShowingClearConfirmation = true
                    } label: {
                        Label("清空全部统计", systemImage: "trash")
                    }
                }

                Section("细粒度统计") {
                    if let stats = model.bucketStats, stats.bucketCount > 0 {
                        LabeledContent("分钟桶数量", value: "\(stats.bucketCount)")
                        LabeledContent(
                            "最早记录",
                            value: formattedDate(stats.earliestBucket)
                        )
                        LabeledContent(
                            "最新记录",
                            value: formattedDate(stats.latestBucket)
                        )
                    } else {
                        Text("尚未积累分钟级统计数据。开始采集后会逐步显示最近时间范围和趋势。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("分钟级数据的保留和清理策略将在后续确定。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
