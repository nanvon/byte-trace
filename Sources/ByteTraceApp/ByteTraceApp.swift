import AppKit
import SwiftUI

@MainActor
final class ByteTraceAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: ByteTraceViewModel?
    private(set) static weak var mainWindow: NSWindow?
    private static var openMainWindowAction: (() -> Void)?
    private static var pendingOpenMainWindowRequest = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.shutdown()
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

    static func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        prepareMainWindow()
    }

    @objc private func handleMainWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === Self.mainWindow else {
            return
        }

        Self.mainWindow = nil
        _ = NSApplication.shared.setActivationPolicy(.accessory)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
