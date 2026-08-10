import AppKit
import UniformTypeIdentifiers
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ByteTraceViewModel
    @State private var isShowingClearConfirmation = false
    @State private var pendingRetentionPolicy: UsageRetentionPolicy?
    @State private var exportMessage: String?
    @State private var exportedFileURL: URL?
    @State private var mihomoControllerDraft = ""
    @State private var mihomoSecretDraft = ""

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

                Section("应用内网站统计") {
                    Toggle(
                        "启用 Mihomo 网站统计",
                        isOn: Binding(
                            get: { model.mihomoEnabled },
                            set: { model.setMihomoEnabled($0) }
                        )
                    )

                    TextField("控制器地址", text: $mihomoControllerDraft)
                        .textFieldStyle(.roundedBorder)
                    SecureField("访问密钥（可选）", text: $mihomoSecretDraft)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("保存并连接") {
                            if model.saveMihomoConfiguration(
                                controllerURL: mihomoControllerDraft,
                                secret: mihomoSecretDraft
                            ) {
                                mihomoControllerDraft = model.mihomoControllerURL
                            }
                        }
                        Button("测试连接") {
                            model.testMihomoConfiguration(
                                controllerURL: mihomoControllerDraft,
                                secret: mihomoSecretDraft
                            )
                        }
                        Spacer()
                        Text(model.mihomoStatus.displayText)
                            .font(.caption)
                            .foregroundStyle(model.mihomoStatus == .connected ? .green : .secondary)
                    }

                    if let message = model.mihomoConfigurationMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Text("仅允许连接本机回环地址，默认 http://127.0.0.1:9090；密钥保存在 macOS 钥匙串。网站统计随 ByteTrace 采集一起开始和停止。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("这里只统计经过 Mihomo 且出现在活动连接快照中的流量，可能漏掉极短连接；网站流量之和不等于应用全部流量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                    Text("默认不自动清理。启用保留周期后，只会删除超过周期的应用与网站分钟级数据，每日汇总和应用信息不受影响。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("关于 ByteTrace") {
                    LabeledContent("应用总量数据源", value: "系统 nettop")
                    LabeledContent("网站排行数据源", value: "可选 Mihomo API")
                    LabeledContent("统计口径", value: "应用逻辑流量")
                    Text("代理运输流量会单独显示，不计入今日应用总量。所有数据仅保存在本机。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .onAppear {
                model.refreshBucketStats()
                mihomoControllerDraft = model.mihomoControllerURL
                mihomoSecretDraft = model.currentMihomoSecret()
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
            Text("此操作会删除本机保存的应用流量、已识别网站流量和采集诊断记录，不能撤销。")
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
