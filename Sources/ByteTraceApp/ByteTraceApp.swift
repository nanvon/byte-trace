import AppKit
import SwiftUI

@MainActor
final class ByteTraceAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: ByteTraceViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.model?.shutdown()
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
