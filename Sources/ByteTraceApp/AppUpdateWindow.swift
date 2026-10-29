import SwiftUI

struct AppUpdateWindow: View {
    let updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(updater.statusText)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.updatesFrequently)
                HStack(spacing: 8) {
                    Text("当前版本 \(updater.currentVersion)")
                    if let version = updater.availableVersion {
                        Image(systemName: "arrow.right")
                            .accessibilityHidden(true)
                        Text(version)
                    }
                    Spacer()
                    if let date = updater.publishedAt {
                        Text(date, format: .dateTime.year().month().day())
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                if updater.hasUpdate, !updater.informationOnly {
                    Text("下载并准备完成后，ByteTrace 会保存统计、安装更新并重新启动。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if updater.hasUpdate {
                        Text("更新日志").font(.headline)
                    }
                    if updater.isLoadingReleaseNotes {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在加载更新日志…")
                        }
                        .foregroundStyle(.secondary)
                    }
                    if !updater.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        UpdateMarkdownView(markdown: updater.releaseNotes)
                    } else if updater.hasUpdate, !updater.isLoadingReleaseNotes, updater.releaseNotesError == nil {
                        Text("此版本未提供更新日志。")
                            .foregroundStyle(.secondary)
                    }
                    if let error = updater.releaseNotesError {
                        Text(error).foregroundStyle(.secondary)
                        Button("在发布页查看日志") { updater.openReleasePage() }
                    }
                    if let error = updater.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    if updater.phase == .upToDate {
                        Text("你正在使用最新版本的 ByteTrace。")
                            .foregroundStyle(.secondary)
                    } else if updater.phase == .idle {
                        Text("检查新版本后，可在这里查看更新日志并安装更新。")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                progress
                HStack(spacing: 12) {
                    if updater.canSkipVersion {
                        Button("跳过此版本") { updater.skipVersion() }
                            .buttonStyle(.borderless)
                    } else if let minimum = updater.minimumSystemVersion, updater.hasUpdate {
                        Text("需要 macOS \(minimum) 或更高版本")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    buttons
                }
                .controlSize(.regular)
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 420)
    }

    @ViewBuilder private var progress: some View {
        if updater.phase == .downloading {
            if let value = updater.downloadProgress {
                ProgressView(value: value)
                    .accessibilityLabel("更新下载进度")
            } else {
                ProgressView().progressViewStyle(.linear)
                    .accessibilityLabel("正在下载更新")
            }
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: updater.downloadedBytes), countStyle: .file))
                if updater.expectedBytes > 0 {
                    Text("/ \(ByteCountFormatter.string(fromByteCount: Int64(clamping: updater.expectedBytes), countStyle: .file))")
                    Spacer()
                    Text("\(Int((updater.downloadProgress ?? 0) * 100))%")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else if updater.phase == .preparing {
            ProgressView("正在准备更新…", value: updater.extractionProgress)
        } else if updater.phase == .checking || updater.phase == .installing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(updater.statusText).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.phase {
        case .available:
            Button("稍后") { updater.closeWindow() }
            Button(updater.informationOnly ? "查看发布说明" : "下载并安装") { updater.installUpdate() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .checking, .downloading:
            Button("取消") { updater.cancel() }
                .disabled(!updater.canCancel)
        case .preparing, .installing:
            EmptyView()
        case .failed:
            Button("手动下载") { updater.openReleasePage() }
            Button(updater.canRetryInstallation ? "重试安装" : "重试") { updater.retry() }
                .buttonStyle(.borderedProminent)
        case .idle:
            Button("检查更新") { updater.checkForUpdates() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .upToDate:
            Button("完成") { updater.closeWindow() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// 原生文本渲染签名 Markdown，不加载远端网页与脚本。
private struct UpdateMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    if line.hasPrefix("## ") {
                        Text(String(line.dropFirst(3))).font(.headline).padding(.top, 8)
                    } else if line.hasPrefix("# ") {
                        Text(String(line.dropFirst(2))).font(.title3.weight(.semibold)).padding(.top, 8)
                    } else if line.hasPrefix("- ") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            inline(String(line.dropFirst(2)))
                        }
                    } else if line == "---" {
                        Divider().padding(.vertical, 4)
                    } else {
                        inline(line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
