import AppKit
import SwiftUI

@MainActor
final class ByteTraceAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: ByteTraceViewModel?
    private(set) static weak var mainWindow: NSWindow?
    static var openMainWindowAction: (() -> Void)?

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
            Self.openMainWindowAction?()
        }
        return true
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
            ByteTraceMenuBarIcon()
        }
        .menuBarExtraStyle(.window)

        Window("ByteTrace", id: "main") {
            MainWindowView(model: model)
        }
        .defaultSize(width: 1080, height: 720)
    }
}
