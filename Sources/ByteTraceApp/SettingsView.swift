import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// 主窗口里推入的设置页：单栏居中的原生分组表单，不单独开窗口。
struct SettingsView: View {
    @ObservedObject var model: ByteTraceViewModel

    @State private var isShowingClearConfirmation = false
    @State private var clearError: String?
    @State private var pendingRetentionPolicy: UsageRetentionPolicy?
    @State private var exportMessage: String?
    @State private var exportedFileURL: URL?
    private let updater = AppUpdater.shared

    private static let maxContentWidth: CGFloat = 600

    var body: some View {
        Form {
            collectionSection
            proxySection
            dataSection
            retentionSection
            aboutSection
        }
        .formStyle(.grouped)
        .scrollIndicators(.never, axes: .vertical)
        .frame(maxWidth: Self.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("设置")
        .onAppear {
            model.refreshBucketStats()
        }
        .confirmationDialog(
            "确定清空全部统计？",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空统计", role: .destructive) {
                do {
                    try model.clearAllData()
                } catch {
                    clearError = error.localizedDescription
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会删除本机保存的每日应用流量和采集诊断记录，不能撤销。")
        }
        .alert("清空统计失败", isPresented: Binding(
            get: { clearError != nil },
            set: { if !$0 { clearError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(clearError ?? "")
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

    // MARK: - 分组

    private var collectionSection: some View {
        Section("采集") {
            Toggle("登录时启动", isOn: Binding(
                get: { model.launchAtLoginEnabled },
                set: { model.setLaunchAtLogin($0) }
            ))
        }
    }

    private var proxySection: some View {
        Section("代理分流") {
            LabeledContent {
                HStack(spacing: 8) {
                    infoIcon("有经代理流量时每秒读取本机 mihomo 的连接列表，区分代理节点与规则直连。字节由 nettop 统计，数据保存在本机。")
                    Toggle("区分代理节点与规则直连", isOn: $model.readsMihomoConnections)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            } label: {
                Text("区分代理节点与规则直连")
                Text("读取本机 mihomo 连接列表。")
            }
            LabeledContent {
                HStack(spacing: 8) {
                    infoIcon("在本机保存主域名和流量，供应用详情和 JSON 导出使用。保存范围为主域名，不含完整网址、IP 和端口。")
                    Toggle("记录访问的域名", isOn: $model.recordsDomains)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!model.readsMihomoConnections)
                        .focusable(false)
                }
            } label: {
                Text("记录访问的域名")
                Text("开启后，应用详情会显示域名用量。导出的 JSON 包含已记录的域名。")
            }
            LabeledContent("连接状态") {
                Text(model.mihomoStatus.title)
                    .lineLimit(1)
            }
        }
    }

    private var dataSection: some View {
        Section("数据") {
            LabeledContent {
                HStack(spacing: 8) {
                    if let exportedFileURL {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([exportedFileURL])
                        }
                    }
                    Button("导出…") { exportCurrentRange() }
                }
            } label: {
                Text("导出当前范围")
                Text(exportMessage ?? "把「\(model.selectedRange.title)」的应用流量导出为 JSON。")
            }
            LabeledContent {
                Button("在 Finder 中显示") { model.revealDatabase() }
            } label: {
                Text("数据库位置")
                Text(model.databaseURL.path)
                    .textSelection(.enabled)
            }
            LabeledContent {
                Button("清空…", role: .destructive) {
                    isShowingClearConfirmation = true
                }
            } label: {
                Text("清空全部统计")
                Text("删除本机保存的全部流量记录，不能撤销。")
            }
        }
    }

    private var retentionSection: some View {
        Section("分钟级数据") {
            Picker(selection: Binding(
                get: { model.usageRetentionPolicy },
                set: { policy in
                    guard policy != model.usageRetentionPolicy else { return }
                    if policy.interval != nil {
                        pendingRetentionPolicy = policy
                    } else {
                        model.usageRetentionPolicy = policy
                    }
                }
            )) {
                ForEach(UsageRetentionPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            } label: {
                Text("保留时长")
                Text("只删除超过周期的分钟级数据，每日汇总和应用信息不受影响。")
            }
            .pickerStyle(.menu)

            if let stats = model.bucketStats, stats.bucketCount > 0 {
                LabeledContent("已记录的时间点") {
                    valueText("\(stats.bucketCount)")
                }
                LabeledContent("记录范围") {
                    valueText("\(formattedDate(stats.earliestBucket)) – \(formattedDate(stats.latestBucket))")
                }
            } else {
                LabeledContent {
                    valueText("0")
                } label: {
                    Text("已记录的时间点")
                    Text("开始统计后会逐步积累。")
                }
            }
        }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本") {
                HStack(spacing: 8) {
                    Text(updater.currentVersion)
                        .textSelection(.enabled)
                    Button("检查更新…") { updater.checkForUpdates() }
                }
            }
            Toggle(isOn: Binding(
                get: { updater.automaticChecks },
                set: { updater.automaticChecks = $0 }
            )) {
                Text("自动检查更新")
                Text(updater.lastCheckedAt.map {
                    "上次检查：\($0.formatted(date: .abbreviated, time: .shortened))。下载与安装由你确认。"
                } ?? "只自动检查新版本，下载与安装由你确认。")
            }
            LabeledContent("数据来源") {
                HStack(spacing: 8) {
                    infoIcon("统计应用逻辑流量；代理传输流量单独显示，不计入应用总量。所有数据只保存在本机。")
                    Text("系统 nettop")
                }
            }
        }
    }

    // MARK: - 控件

    /// 行右侧控件前的 ⓘ，点击弹出完整说明。设置页里 `.help` 悬停提示不显示，改用 popover。
    private func infoIcon(_ info: String) -> some View {
        SettingsInfoButton(text: info)
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .monospacedDigit()
            .lineLimit(1)
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

/// 点击 ⓘ 弹出说明文字。
private struct SettingsInfoButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel("说明")
        .accessibilityHint(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}
