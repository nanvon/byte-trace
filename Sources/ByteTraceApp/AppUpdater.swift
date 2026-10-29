import AppKit
import Observation
import Sparkle
import SwiftUI

enum AppUpdatePhase: Equatable {
    case idle, checking, available, downloading, preparing, installing, upToDate, failed
}

/// 更新会话与窗口同属应用生命周期，收起菜单栏或关闭窗口不会中断下载。
@Observable
@MainActor
final class AppUpdater: NSObject, SPUUserDriver, SPUUpdaterDelegate, NSWindowDelegate {
    static let shared = AppUpdater()
    static let releasePageURL = URL(string: "https://github.com/nanvon/byte-trace/releases/latest")!

    private(set) var phase: AppUpdatePhase = .idle
    private(set) var availableVersion: String?
    private(set) var publishedAt: Date?
    private(set) var minimumSystemVersion: String?
    private(set) var releaseNotes = ""
    private(set) var isLoadingReleaseNotes = false
    private(set) var releaseNotesError: String?
    private(set) var errorMessage: String?
    private(set) var downloadedBytes: UInt64 = 0
    private(set) var expectedBytes: UInt64 = 0
    private(set) var extractionProgress: Double = 0
    private(set) var lastCheckedAt: Date?
    private(set) var informationOnly = false

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var item: SUAppcastItem?
    @ObservationIgnored private var updateReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var retryTermination: (() -> Void)?
    @ObservationIgnored private var installWasRequested = false
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var configurationError: String?
    @ObservationIgnored private var checkObservation: NSKeyValueObservation?
    @ObservationIgnored private var isWaitingToCheck = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
    }

    var automaticChecks: Bool {
        get {
            access(keyPath: \.automaticChecks)
            return updater?.automaticallyChecksForUpdates
                ?? (UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool ?? true)
        }
        set {
            withMutation(keyPath: \.automaticChecks) {
                UserDefaults.standard.set(newValue, forKey: "SUEnableAutomaticChecks")
                updater?.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var hasUpdate: Bool { availableVersion != nil }
    var isWorking: Bool { [.checking, .downloading, .preparing, .installing].contains(phase) }
    var canCancel: Bool { cancellation != nil || isWaitingToCheck }
    var canSkipVersion: Bool { phase == .available && updateReply != nil && !informationOnly }
    var canRetryInstallation: Bool { retryTermination != nil }
    var downloadProgress: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1, Double(downloadedBytes) / Double(expectedBytes))
    }

    var statusText: String {
        switch phase {
        case .idle: return "检查是否有新版本"
        case .checking: return "正在检查更新…"
        case .available: return "发现新版本 \(availableVersion ?? "")"
        case .downloading: return "正在下载更新…"
        case .preparing: return "正在验证并准备更新…"
        case .installing: return "正在保存统计并重新启动…"
        case .upToDate: return "已是最新版本"
        case .failed: return "更新未能完成"
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        guard Bundle.main.bundleURL.pathExtension == "app",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            configurationError = "此构建未启用应用内更新，请使用已打包的 ByteTrace 应用，或从发布页下载。"
            return
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            self.updater = updater
            lastCheckedAt = updater.lastUpdateCheckDate
            checkObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                guard change.newValue == true else { return }
                Task { @MainActor [weak self] in self?.performPendingCheck() }
            }
        } catch {
            configurationError = "无法启动更新服务：\(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        start()
        showUpdateWindow()
        guard !isWorking, updateReply == nil, retryTermination == nil else { return }
        if let configurationError {
            errorMessage = configurationError
            phase = .failed
            return
        }
        guard let updater else { return }
        errorMessage = nil
        phase = .checking
        if updater.canCheckForUpdates {
            updater.checkForUpdates()
        } else {
            isWaitingToCheck = true
        }
    }

    private func performPendingCheck() {
        guard isWaitingToCheck, let updater, updater.canCheckForUpdates else { return }
        isWaitingToCheck = false
        guard updateReply == nil else { return }
        phase = .checking
        updater.checkForUpdates()
    }

    func installUpdate() {
        guard phase == .available else { return }
        guard let reply = updateReply else {
            checkForUpdates()
            return
        }
        updateReply = nil
        if informationOnly {
            openReleasePage()
            reply(.dismiss)
            return
        }
        installWasRequested = true
        phase = .downloading
        reply(.install)
    }

    func skipVersion() {
        guard canSkipVersion, let reply = updateReply else { return }
        updateReply = nil
        clearUpdate()
        phase = .idle
        reply(.skip)
        closeWindow()
    }

    func cancel() {
        if isWaitingToCheck {
            isWaitingToCheck = false
            phase = hasUpdate ? .available : .idle
            return
        }
        guard let cancellation else { return }
        self.cancellation = nil
        installWasRequested = false
        cancellation()
        phase = hasUpdate ? .available : .idle
    }

    func retry() {
        errorMessage = nil
        if let retryTermination {
            phase = .installing
            retryTermination()
        } else {
            checkForUpdates()
        }
    }

    func terminationPreparationFailed(_ error: Error) {
        errorMessage = "统计保存失败，已暂停安装：\(error.localizedDescription)。请重试安装。"
        phase = .failed
        showUpdateWindow()
    }

    func openReleasePage() {
        let url = item?.infoURL ?? Self.releasePageURL
        guard url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    func showUpdateWindow() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "ByteTrace 更新"
            window.contentView = NSHostingView(rootView: AppUpdateWindow(updater: self))
            window.minSize = NSSize(width: 500, height: 420)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func closeWindow() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        if phase == .available {
            // 结束本次提示，后续自动检查仍可继续；再次安装会重新检查并获取新回调。
            let reply = updateReply
            updateReply = nil
            reply?(.dismiss)
        } else if phase == .checking {
            cancel()
        }
    }

    private func clearUpdate() {
        availableVersion = nil
        item = nil
        releaseNotes = ""
        releaseNotesError = nil
        isLoadingReleaseNotes = false
    }

    private func recordNoUpdate(_ error: Error) {
        isWaitingToCheck = false
        cancellation = nil
        clearUpdate()
        let error = error as NSError
        let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
        // Sparkle 另有系统/架构不兼容原因，不能一律显示“已是最新版本”。
        phase = (reason == 1 || reason == 2) ? .upToDate : .failed
        errorMessage = phase == .failed ? "没有适用于当前系统与设备的更新。请在发布页查看版本要求。" : nil
    }

    // MARK: - SPUUserDriver（Sparkle 在主线程回调）

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticChecks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        errorMessage = nil
        phase = .checking
        showUpdateWindow()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        isWaitingToCheck = false
        cancellation = nil
        retryTermination = nil
        installWasRequested = false
        item = appcastItem
        availableVersion = appcastItem.displayVersionString
        publishedAt = appcastItem.date
        minimumSystemVersion = appcastItem.minimumSystemVersion
        informationOnly = appcastItem.isInformationOnlyUpdate
        expectedBytes = appcastItem.contentLength
        downloadedBytes = 0
        extractionProgress = 0
        releaseNotes = appcastItem.itemDescription ?? ""
        releaseNotesError = nil
        errorMessage = nil
        isLoadingReleaseNotes = appcastItem.releaseNotesURL != nil
        updateReply = reply
        phase = .available
        lastCheckedAt = updater?.lastUpdateCheckDate ?? .now
        if state.userInitiated { showUpdateWindow() }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        isLoadingReleaseNotes = false
        guard let notes = String(data: downloadData.data, encoding: .utf8) else {
            releaseNotesError = "更新日志无法显示，可在发布页查看。"
            return
        }
        releaseNotes = UpdateReleaseNotes.changes(in: notes, since: currentVersion)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        isLoadingReleaseNotes = false
        releaseNotesError = "更新日志加载失败，可在发布页查看。"
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        recordNoUpdate(error)
        showUpdateWindow()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        isWaitingToCheck = false
        cancellation = nil
        updateReply = nil
        installWasRequested = false
        isLoadingReleaseNotes = false
        errorMessage = "检查或安装更新失败：\(error.localizedDescription)"
        phase = .failed
        showUpdateWindow()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        downloadedBytes = 0
        phase = .downloading
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { expectedBytes = expectedContentLength }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (total, overflow) = downloadedBytes.addingReportingOverflow(length)
        downloadedBytes = overflow ? .max : total
    }
    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        phase = .preparing
    }
    func showExtractionReceivedProgress(_ progress: Double) { extractionProgress = min(1, max(0, progress)) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard installWasRequested else {
            updateReply = reply
            phase = .available
            return
        }
        phase = .installing
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        cancellation = nil
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        phase = .idle
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        updateReply = nil
        cancellation = nil
        retryTermination = nil
        installWasRequested = false
        if isWorking { phase = hasUpdate ? .available : .idle }
    }

    func showUpdateInFocus() { showUpdateWindow() }

    // MARK: - SPUUpdaterDelegate

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        recordNoUpdate(error)
        lastCheckedAt = updater.lastUpdateCheckDate ?? .now
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        lastCheckedAt = updater.lastUpdateCheckDate
        if phase == .checking {
            isWaitingToCheck = false
            if let error {
                errorMessage = "检查更新失败：\(error.localizedDescription)"
                phase = .failed
            } else {
                phase = hasUpdate ? .available : .idle
            }
        }
    }
}

/// 历史日志只展示当前版本之后的变化，单版 Markdown 仍可直接显示。
enum UpdateReleaseNotes {
    static func changes(in markdown: String, since version: String) -> String {
        var result: [String] = []
        var hasVersionHeadings = false
        var include = true
        for line in markdown.components(separatedBy: .newlines) {
            if line.range(of: "^## v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil {
                hasVersionHeadings = true
                let tag = String(line.dropFirst(4))
                include = tag.compare(version, options: .numeric) == .orderedDescending
            }
            if include { result.append(line) }
        }
        return hasVersionHeadings
            ? result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : markdown
    }
}
