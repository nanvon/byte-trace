import AppKit
import SwiftUI

@MainActor
final class ByteTraceAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: ByteTraceViewModel?
    private static var openMainWindowAction: (() -> Void)?
    private static var pendingOpenMainWindowRequest = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppUpdater.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppUpdater.shared.phase == .installing {
            do {
                try Self.model?.prepareForUpdate()
            } catch {
                AppUpdater.shared.terminationPreparationFailed(error)
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.requestOpenMainWindow()
        }
        return true
    }

    /// 安装打开主窗口的回调；若此前已有点击 Dock 图标的请求排队(回调还没就绪就先触发过 reopen)，立即补执行一次。
    static func installOpenMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindowAction = action
        guard pendingOpenMainWindowRequest else { return }
        pendingOpenMainWindowRequest = false
        action()
    }

    private static func requestOpenMainWindow() {
        guard let openMainWindowAction else {
            pendingOpenMainWindowRequest = true
            return
        }
        openMainWindowAction()
    }

    static func prepareMainWindow() {
        _ = NSApplication.shared.setActivationPolicy(.regular)
    }

    /// 主窗口与设置窗口打开的数量；全部关闭后才回到纯菜单栏形态，避免关掉其中一个时另一个失去 Dock 图标。
    private static var visibleWindowCount = 0

    static func windowDidAppear() {
        visibleWindowCount += 1
        prepareMainWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    static func windowDidDisappear() {
        visibleWindowCount = max(0, visibleWindowCount - 1)
        if visibleWindowCount == 0 {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}

@main
struct ByteTraceApp: App {
    @NSApplicationDelegateAdaptor(ByteTraceAppDelegate.self)
    private var appDelegate

    @StateObject private var model: ByteTraceViewModel

    init() {
        let model = ByteTraceViewModel()
        _model = StateObject(wrappedValue: model)
        ByteTraceAppDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            MenuBarIconRoot()
        }
        .menuBarExtraStyle(.window)

        Window("ByteTrace", id: "main") {
            MainWindowView(model: model)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { AppUpdater.shared.checkForUpdates() }
            }
            CommandGroup(replacing: .appSettings) {
                OpenSettingsCommand()
            }
        }

        Window("设置", id: "settings") {
            SettingsView(model: model)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 640)
                .onAppear { ByteTraceAppDelegate.windowDidAppear() }
                .onDisappear { ByteTraceAppDelegate.windowDidDisappear() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 640)
    }
}

/// 菜单「设置…」（⌘,）打开独立的设置窗口。
private struct OpenSettingsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("设置…") {
            ByteTraceAppDelegate.prepareMainWindow()
            openWindow(id: "settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// 菜单栏图标从 App 启动起就常驻渲染（不像主窗口要等用户打开过一次才有 onAppear），
/// 借它的 onAppear 尽早装好「打开主窗口」回调，让冷启动后第一次点 Dock 图标就能生效。
private struct MenuBarIconRoot: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ByteTraceMenuBarIcon()
            .onAppear {
                ByteTraceAppDelegate.installOpenMainWindowAction {
                    ByteTraceAppDelegate.prepareMainWindow()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
            }
    }
}
